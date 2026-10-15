import BiliApplication
import BiliModels
import Foundation
import Observation

public enum WatchHistoryState: Sendable, Equatable {
    case idle
    case loading
    case loaded(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?,
        loadMoreError: WatchHistoryError?
    )
    case loadingMore(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation
    )
    case failed(WatchHistoryError)
}

@MainActor
@Observable
/// 拥有当前登录会话的历史工作集、分页 continuation 与最新请求 Task。
///
/// `reset` 会清除个性化内容；普通路由停用只取消在途请求，并在分页中断时保留已显示条目。
/// 已有条目时刷新原地进行：条目保持显示，成功后整体替换，失败时保留条目并给出 `refreshError`。
public final class WatchHistoryViewModel {
    public private(set) var state: WatchHistoryState = .idle
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 已有条目时的原地刷新正在进行；首次加载仍是 `.loading`。
    public private(set) var isRefreshing = false
    /// 最近一次原地刷新失败的原因，条目仍是刷新前的内容；下一次刷新开始时清除。
    public private(set) var refreshError: WatchHistoryError?
    /// 仅供 renderer 对 near-end 事件去重；不包含或编码远端 continuation。
    public private(set) var paginationTailIdentity: String?
    /// 空页或全重复页保留 continuation 时，必须由用户显式继续，避免 near-end 连续扫描。
    public private(set) var requiresManualLoadMore = false

    public var requiresAuthentication: Bool {
        switch state {
        case .failed(.authenticationRequired),
            .loaded(_, _, .authenticationRequired):
            true
        default:
            false
        }
    }

    public var isBusy: Bool {
        if isRefreshing { return true }
        switch state {
        case .loading, .loadingMore:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }

    @ObservationIgnored private let useCase: WatchHistoryUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var tailIdentityGeneration: UInt64 = 0
    @ObservationIgnored private var loadingMoreWasManual = false
    @ObservationIgnored private var consumedContinuations: [WatchHistoryContinuation] = []
    /// 原地刷新开始前的分页状态；刷新失败或离开页面时原样恢复，条目没被替换就不改变分页行为。
    @ObservationIgnored private var refreshRestorePoint: PaginationRestorePoint?

    private struct PaginationRestorePoint {
        let tailIdentity: String?
        let requiresManualLoadMore: Bool
        let consumedContinuations: [WatchHistoryContinuation]
    }

    public init(useCase: WatchHistoryUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded() {
        guard state == .idle else { return }
        reload()
    }

    public func reload() {
        // 已有条目时原地刷新，与首页、热门一致：网格不卸载，成功后由刷新代次回到顶部。
        let initialState: WatchHistoryState
        let restorePoint: PaginationRestorePoint?
        switch state {
        case .loaded(let items, let continuation, _) where !items.isEmpty:
            initialState = .loaded(items: items, continuation: continuation, loadMoreError: nil)
            restorePoint = PaginationRestorePoint(
                tailIdentity: paginationTailIdentity,
                requiresManualLoadMore: requiresManualLoadMore,
                consumedContinuations: consumedContinuations
            )
        case .loadingMore(let items, let continuation):
            initialState = .loaded(items: items, continuation: continuation, loadMoreError: nil)
            restorePoint = PaginationRestorePoint(
                tailIdentity: paginationTailIdentity,
                requiresManualLoadMore: loadingMoreWasManual,
                consumedContinuations: consumedContinuations
            )
        case .idle, .loading, .loaded, .failed:
            initialState = .loading
            restorePoint = nil
        }
        let keepsItems = restorePoint != nil
        clearTailIdentity()
        requiresManualLoadMore = false
        loadingMoreWasManual = false
        consumedContinuations.removeAll(keepingCapacity: false)
        refreshError = nil
        refreshRestorePoint = restorePoint
        isRefreshing = keepsItems
        begin(state: initialState) { [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.load()
                guard isCurrent() else { return }
                isRefreshing = false
                refreshRestorePoint = nil
                let first = [].appendingVideoPage(page.items, \.bvid)
                let continuation = first.isAtCapacity ? nil : page.continuation
                applyLoaded(
                    items: first.items,
                    continuation: continuation,
                    loadMoreError: nil,
                    rearmAutomaticTail: !first.items.isEmpty,
                    requiresManualLoadMore: first.items.isEmpty && continuation != nil
                )
                successfulReloadGeneration &+= 1
            } catch {
                guard isCurrent() else { return }
                isRefreshing = false
                let failure = error as? WatchHistoryError ?? .transportFailure
                // 原地刷新失败保留已显示条目；登录失效与会话切换带来的取消仍进入终态，交给登录提示或重试。
                if keepsItems, failure != .authenticationRequired, !(error is CancellationError) {
                    refreshError = failure
                    restorePaginationAfterRefresh()
                } else {
                    refreshRestorePoint = nil
                    state = .failed(failure)
                }
            }
        }
    }

    public func loadMore() {
        guard !isRefreshing,
            case .loaded(let items, .some(let continuation), _) = state
        else { return }
        loadingMoreWasManual = requiresManualLoadMore
        requiresManualLoadMore = false
        begin(state: .loadingMore(items: items, continuation: continuation)) {
            [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.load(after: continuation)
                guard isCurrent() else { return }
                let append = items.appendingVideoPage(page.items, \.bvid)
                // 每页至少并入一条才自动继续，因此自动翻页的页数随条目上限有界；没有新条目的页
                // 要用户显式继续，同样以条目上限为页数上限，`consumedContinuations` 的线性查找随之有界。
                consumedContinuations.append(continuation)
                let continuationLoops =
                    page.continuation.map {
                        consumedContinuations.contains($0)
                    } ?? false
                let reachedLimit =
                    append.isAtCapacity
                    || consumedContinuations.count >= VideoListRetention.maximumItemCount
                let nextContinuation =
                    continuationLoops || reachedLimit ? nil : page.continuation
                applyLoaded(
                    items: append.items,
                    continuation: nextContinuation,
                    loadMoreError: continuationLoops && !reachedLimit ? .invalidResponse : nil,
                    rearmAutomaticTail: nextContinuation != nil && append.appendedCount > 0,
                    requiresManualLoadMore: nextContinuation != nil && append.appendedCount == 0
                )
            } catch {
                guard isCurrent() else { return }
                // 认证切换带来的取消只保留已显示条目，并要求用户显式继续。
                let wasCancelled = error is CancellationError
                applyLoaded(
                    items: items,
                    continuation: continuation,
                    loadMoreError: wasCancelled
                        ? nil : error as? WatchHistoryError ?? .transportFailure,
                    rearmAutomaticTail: false,
                    requiresManualLoadMore: wasCancelled || loadingMoreWasManual
                )
            }
        }
    }

    /// 取消请求并从内存删除全部个性化历史，供登出与窗口关闭调用。
    public func reset() {
        loadTask.cancel()
        clearTailIdentity()
        requiresManualLoadMore = false
        loadingMoreWasManual = false
        consumedContinuations.removeAll(keepingCapacity: false)
        isRefreshing = false
        refreshError = nil
        refreshRestorePoint = nil
        state = .idle
    }

    /// 停用页面请求而不抹掉已加载条目；迟到结果由 `LatestTask` 拒绝。
    public func deactivateRoute() {
        loadTask.cancel()
        refreshError = nil
        if isRefreshing {
            isRefreshing = false
            restorePaginationAfterRefresh()
        }
        switch state {
        case .loading:
            state = .idle
        case .loadingMore(let items, let continuation):
            requiresManualLoadMore = loadingMoreWasManual
            loadingMoreWasManual = false
            state = .loaded(
                items: items,
                continuation: continuation,
                loadMoreError: nil
            )
        case .idle, .loaded, .failed:
            break
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 认证重新确认失败时保持已清理的隐私边界，并给 History 提供可重试的终态。
    public func reportAuthenticationRevalidationFailure() {
        guard state == .idle else { return }
        state = .failed(.transportFailure)
    }

    private func begin(
        state initialState: WatchHistoryState,
        operation: @escaping @MainActor (_ isCurrent: @escaping LatestTask.IsCurrent) async -> Void
    ) {
        state = initialState
        loadTask.replace(operation)
    }

    private func applyLoaded(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation?,
        loadMoreError: WatchHistoryError?,
        rearmAutomaticTail: Bool,
        requiresManualLoadMore: Bool
    ) {
        self.requiresManualLoadMore = requiresManualLoadMore
        loadingMoreWasManual = false
        if continuation == nil || requiresManualLoadMore {
            paginationTailIdentity = nil
        } else if rearmAutomaticTail {
            tailIdentityGeneration &+= 1
            paginationTailIdentity = "history-tail-\(tailIdentityGeneration)"
        }
        state = .loaded(
            items: items,
            continuation: continuation,
            loadMoreError: loadMoreError
        )
    }

    private func clearTailIdentity() {
        paginationTailIdentity = nil
    }

    /// 原地刷新开始时收起了分页尾标；刷新没有替换条目时原样恢复刷新前的分页状态。
    private func restorePaginationAfterRefresh() {
        guard let point = refreshRestorePoint else { return }
        refreshRestorePoint = nil
        paginationTailIdentity = point.tailIdentity
        requiresManualLoadMore = point.requiresManualLoadMore
        consumedContinuations = point.consumedContinuations
    }
}
