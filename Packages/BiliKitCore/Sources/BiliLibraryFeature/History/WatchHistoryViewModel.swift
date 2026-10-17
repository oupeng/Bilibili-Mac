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
        loadMoreError: ContentApplicationError?
    )
    case loadingMore(
        items: [WatchHistoryItem],
        continuation: WatchHistoryContinuation
    )
    case failed(ContentApplicationError)
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
    public private(set) var refreshError: ContentApplicationError?
    /// 仅供 renderer 对 near-end 事件去重的尾标计数；不包含或编码远端 continuation。
    public private(set) var paginationTailIdentity: UInt64?
    /// 空页或全重复页保留 continuation 时，必须由用户显式继续，避免 near-end 连续扫描。
    public private(set) var requiresManualLoadMore = false
    /// 历史读取发现凭据失效时递增，由 App 层汇总后复核账户（与其他内容页同一契约）。
    ///
    /// 历史页只在已登录时渲染，所以读取时本地没有凭据也说明窗口的登录状态已过期，同样递增。
    public private(set) var authenticationRevalidationGeneration = 0
    /// 本页因凭据缺失或失效请求了账户复核、复核尚未结束；失败页据此显示“正在重新确认”。
    ///
    /// 复核结束（`resumeAfterAuthenticationRevalidation`／`reportAuthenticationRevalidationFailure`）、
    /// 加载成功、离开页面或 `reset` 时清除。
    public private(set) var isAwaitingAuthenticationRevalidation = false

    public var isBusy: Bool {
        if isRefreshing { return true }
        switch state {
        case .loading, .loadingMore:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }

    /// 一次加载会话最多翻的页数。
    ///
    /// 自动翻页每页至少并入一条，页数已随 `VideoListRetention` 的条目上限有界；没有新条目的页要用户
    /// 显式继续，不受条目上限约束，另以此封顶，`consumedContinuations` 的线性查找随之有界。按每页 20 条，
    /// 1000 条约 50 页，这里留出同样多的空页或全重复页余量。
    private static let maximumLoadedPages = 100

    @ObservationIgnored private let useCase: WatchHistoryUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var tailIdentityGeneration: UInt64 = 0
    @ObservationIgnored private var loadingMoreWasManual = false
    @ObservationIgnored private var consumedContinuations: [WatchHistoryContinuation] = []
    /// 原地刷新开始前的分页状态；刷新失败或离开页面时原样恢复，条目没被替换就不改变分页行为。
    @ObservationIgnored private var refreshRestorePoint: PaginationRestorePoint?
    /// 复核后已自动重载过一次，加载成功或 `reset` 时清除。
    ///
    /// 复核确认仍登录而重载又得到凭据失效时不再自动重载，挡住连续的“复核 → 重载 → 失效 → 复核”。
    @ObservationIgnored private var hasReloadedAfterRevalidation = false

    private struct PaginationRestorePoint {
        let tailIdentity: UInt64?
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
                isAwaitingAuthenticationRevalidation = false
                hasReloadedAfterRevalidation = false
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。不是网络失败；已有条目原样保留，
                // 否则回到 idle，由会话切换后的复核与 `resumeAfterAuthenticationRevalidation` 重新加载。
                guard isCurrent() else { return }
                isRefreshing = false
                if keepsItems {
                    restorePaginationAfterRefresh()
                } else {
                    refreshRestorePoint = nil
                    state = .idle
                }
            } catch {
                guard isCurrent() else { return }
                isRefreshing = false
                let failure = error as? ContentApplicationError ?? .unavailable
                recordAuthenticationFailureIfNeeded(failure)
                // 原地刷新失败保留已显示条目；凭据缺失或失效进入终态，条目不再显示。
                if keepsItems, !Self.isCredentialFailure(failure) {
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
                consumedContinuations.append(continuation)
                let continuationLoops =
                    page.continuation.map {
                        consumedContinuations.contains($0)
                    } ?? false
                let reachedLimit =
                    append.isAtCapacity
                    || consumedContinuations.count >= Self.maximumLoadedPages
                let nextContinuation =
                    continuationLoops || reachedLimit ? nil : page.continuation
                applyLoaded(
                    items: append.items,
                    continuation: nextContinuation,
                    // 回环是接口异常，即使恰好同时达到上限也要报告。
                    loadMoreError: continuationLoops ? .invalidResponse : nil,
                    rearmAutomaticTail: nextContinuation != nil && append.appendedCount > 0,
                    requiresManualLoadMore: nextContinuation != nil && append.appendedCount == 0
                )
            } catch {
                guard isCurrent() else { return }
                // 认证切换带来的取消只保留已显示条目，并要求用户显式继续。
                let wasCancelled = error is CancellationError
                let failure: ContentApplicationError? =
                    wasCancelled ? nil : error as? ContentApplicationError ?? .unavailable
                // 与刷新一致：凭据缺失或失效时不再显示该账户的条目，转入失败页并请求复核。
                if let failure, Self.isCredentialFailure(failure) {
                    recordAuthenticationFailureIfNeeded(failure)
                    clearPagination()
                    state = .failed(failure)
                    return
                }
                applyLoaded(
                    items: items,
                    continuation: continuation,
                    loadMoreError: failure,
                    rearmAutomaticTail: false,
                    requiresManualLoadMore: wasCancelled || loadingMoreWasManual
                )
            }
        }
    }

    /// 取消请求并从内存删除全部个性化历史，供登出与窗口关闭调用。
    public func reset() {
        loadTask.cancel()
        clearPagination()
        isRefreshing = false
        refreshError = nil
        refreshRestorePoint = nil
        isAwaitingAuthenticationRevalidation = false
        hasReloadedAfterRevalidation = false
        state = .idle
    }

    /// 停用页面请求而不抹掉已加载条目；迟到结果由 `LatestTask` 拒绝。
    ///
    /// 离开页面后 App 不再把复核结果交给本页：停止等待复核，凭据失败页回到 idle，回来时重新加载。
    public func deactivateRoute() {
        loadTask.cancel()
        refreshError = nil
        isAwaitingAuthenticationRevalidation = false
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
        case .failed(let failure) where Self.isCredentialFailure(failure):
            state = .idle
        case .idle, .loaded, .failed:
            break
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 账户复核确认仍已登录（或会话切换后重新确认）时调用。
    ///
    /// 本页因凭据失效请求的复核，确认后自动重载一次；同一会话内只做一次，之后再失效只显示失败、
    /// 由用户重试。其余情况只在 idle 时加载。
    public func resumeAfterAuthenticationRevalidation() {
        let requestedRevalidation = isAwaitingAuthenticationRevalidation
        isAwaitingAuthenticationRevalidation = false
        guard requestedRevalidation, !hasReloadedAfterRevalidation else {
            loadIfNeeded()
            return
        }
        hasReloadedAfterRevalidation = true
        reload()
    }

    /// 账户复核没能确认登录状态（网络或 Keychain 不可用）。
    ///
    /// 给出可重试的“无法读取登录状态”，不是网络失败。凭据失败时条目已清空；隐私清理仍由账户范围
    /// 变化负责。
    public func reportAuthenticationRevalidationFailure() {
        let requestedRevalidation = isAwaitingAuthenticationRevalidation
        isAwaitingAuthenticationRevalidation = false
        switch state {
        case .idle:
            state = .failed(.authenticationUnavailable)
        case .failed where requestedRevalidation:
            state = .failed(.authenticationUnavailable)
        case .loading, .loadingMore, .loaded, .failed:
            break
        }
    }

    /// 凭据缺失或失效：原地刷新不保留条目，并请求窗口复核账户。
    private static func isCredentialFailure(_ error: ContentApplicationError) -> Bool {
        error == .authenticationRequired || error.requiresAccountRevalidation
    }

    private func recordAuthenticationFailureIfNeeded(_ error: ContentApplicationError) {
        guard Self.isCredentialFailure(error) else { return }
        isAwaitingAuthenticationRevalidation = true
        authenticationRevalidationGeneration &+= 1
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
        loadMoreError: ContentApplicationError?,
        rearmAutomaticTail: Bool,
        requiresManualLoadMore: Bool
    ) {
        self.requiresManualLoadMore = requiresManualLoadMore
        loadingMoreWasManual = false
        if continuation == nil || requiresManualLoadMore {
            paginationTailIdentity = nil
        } else if rearmAutomaticTail {
            tailIdentityGeneration &+= 1
            paginationTailIdentity = tailIdentityGeneration
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

    private func clearPagination() {
        clearTailIdentity()
        requiresManualLoadMore = false
        loadingMoreWasManual = false
        consumedContinuations.removeAll(keepingCapacity: false)
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
