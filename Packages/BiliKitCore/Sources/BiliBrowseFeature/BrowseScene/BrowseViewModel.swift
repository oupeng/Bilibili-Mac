import BiliApplication
import BiliModels
import Foundation
import Observation

enum FeedState: Sendable, Equatable {
    case idle
    case loading(FeedRequest)
    case loaded(FeedListing)
    case failed(request: FeedRequest, error: ContentApplicationError)
}

struct FeedPresentation: Sendable, Equatable {
    let state: FeedState
    let isRefreshing: Bool
    let refreshError: ContentApplicationError?
}

/// 首页推荐、热门与搜索三个来源；各自拥有独立工作集，互不共享可被污染的状态。
public enum FeedSource: Sendable, Hashable, CaseIterable {
    case recommendation
    case popular
    case search
}

extension FeedRequest {
    var source: FeedSource {
        switch self {
        case .recommendation: .recommendation
        case .popular: .popular
        case .search: .search
        }
    }
}

/// 推荐、热门与搜索共用的分页 footer 投影。
///
/// `tailIdentity` 是 `PagedVideoList` 的尾标计数，只在仍可自动加载时给出；失败、原地刷新与到底时为 nil。
struct FeedPaginationPresentation: Sendable, Equatable {
    static let unavailable = FeedPaginationPresentation(
        tailIdentity: nil,
        isLoadingMore: false,
        loadMoreError: nil
    )

    let tailIdentity: UInt64?
    let isLoadingMore: Bool
    let loadMoreError: ContentApplicationError?

    var canLoadMore: Bool { tailIdentity != nil }
}

@MainActor
@Observable
/// 拥有首页推荐、热门与最后一次搜索三份独立工作集，以及当前路由的请求 Task。
///
/// 工作集是唯一的状态来源，路由级的 `state` 等只是当前路由工作集的投影。`LatestTask` 与
/// `activeRequestIdentity` 共同阻止已取消或已切路由的结果写回；进入播放页时普通 deactivate 会保留三份
/// 工作集，`reset` 则清空它们；不同请求会替换对应工作集。分页规则由各工作集的 `FeedListing` 承担。
public final class BrowseViewModel: AccountRevalidationParticipant {
    public private(set) var authenticationRevalidationGeneration = 0
    private var successfulRefreshGenerations: [FeedSource: UInt64] = [:]
    private(set) var activeRequestIdentity: FeedRequest?

    @ObservationIgnored private let useCase: FeedUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private var authenticationSessionGeneration: UInt64?
    private var worksets: [FeedSource: FeedWorkset] = [:]

    public init(useCase: FeedUseCase) {
        self.useCase = useCase
    }

    /// 当前路由的状态；路由停用后为 idle，工作集仍保留供返回时恢复。
    var state: FeedState {
        activeWorkset?.state ?? .idle
    }

    var isRefreshing: Bool {
        activeWorkset?.isRefreshing ?? false
    }

    var refreshError: ContentApplicationError? {
        activeWorkset?.refreshError
    }

    public func activateRecommendation() {
        activateWorkset(.recommendation(continuation: nil))
    }

    /// App 热门 Tab 使用的分页大小；`PopularFeedView` 按同一请求匹配 presentation。
    public static let popularPageSize = 50

    public func activatePopular(page: Int = 1, pageSize: Int = 20) {
        activateWorkset(.popular(page: page, pageSize: pageSize))
    }

    public func activateSearch(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        activateWorkset(request)
    }

    func refreshPopular(page: Int = 1, pageSize: Int = 20) {
        refresh(.popular(page: page, pageSize: pageSize))
    }

    func refreshRecommendation() {
        refresh(.recommendation(continuation: nil))
    }

    /// 该来源刷新成功的次数；App 只在它前进时把对应网格滚回顶部。
    public func successfulRefreshGeneration(for source: FeedSource) -> UInt64 {
        successfulRefreshGenerations[source, default: 0]
    }

    /// 为当前路由的来源加载下一页；近尾自动加载与失败后的重试共用，没有其他请求时才发出。
    public func loadMore(_ source: FeedSource) {
        guard
            let baseRequest = activeRequestIdentity,
            baseRequest.source == source,
            !loadTask.isRunning,
            var workset = activeWorkset,
            case .loaded(var listing) = workset.state,
            let nextRequest = listing.beginLoadMore()
        else {
            return
        }
        workset.state = .loaded(listing)
        worksets[source] = workset
        loadTask.replace { [weak self] isCurrent in
            await self?.performAppend(
                nextRequest,
                baseRequest: baseRequest,
                isCurrent: isCurrent
            )
        }
    }

    public func search(_ criteria: VideoSearchCriteria) {
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: criteria, page: 1)
        )
        guard criteria.isValid else {
            fail(request: request, error: .invalidRequest)
            return
        }
        refresh(request)
    }

    /// 丢弃上一账户范围的推荐、热门与搜索工作集；当前路由会以同一请求重新开始。
    public func synchronizeAuthenticationSession(generation newGeneration: UInt64) {
        guard authenticationSessionGeneration != newGeneration else { return }
        authenticationSessionGeneration = newGeneration

        let activeRequest = activeRequestIdentity
        loadTask.cancel()
        activeRequestIdentity = nil
        worksets = [:]
        switch activeRequest {
        case .recommendation:
            activateRecommendation()
        case .popular(let page, let pageSize):
            activatePopular(page: page, pageSize: pageSize)
        case .search(let request):
            activateSearch(request.criteria)
        case nil:
            break
        }
    }

    func retry(_ request: FeedRequest) {
        guard
            case .failed(let failedRequest, _) =
                presentation(for: request).state,
            failedRequest == request
        else {
            return
        }
        refresh(request)
    }

    /// 停止当前路由工作，把工作集规范化（结束刷新与加载更多）后保留，供返回时恢复。
    public func deactivateRoute() {
        loadTask.cancel()
        normalizeInterruptedLoad()
        activeRequestIdentity = nil
    }

    /// 取消请求并丢弃三份内存工作集，适用于窗口关闭而非普通页面 push/pop。
    public func reset() {
        deactivateRoute()
        worksets = [:]
    }

    func presentation(
        for request: FeedRequest
    ) -> FeedPresentation {
        let workset = workset(for: request)
        return FeedPresentation(
            state: workset?.state ?? .idle,
            isRefreshing: workset?.isRefreshing ?? false,
            refreshError: workset?.refreshError
        )
    }

    /// 分页 footer 投影；`request` 是该来源工作集的第一页请求。
    ///
    /// 原地刷新期间没有尾标：网格对同一尾标只触发一次，刷新中被忽略的近尾事件、或刷新取消的加载更多，
    /// 都要等尾标重新出现（刷新失败恢复原尾标、成功给出新尾标）才会再次布防。
    func pagination(for request: FeedRequest) -> FeedPaginationPresentation {
        guard case .loaded(let listing) = workset(for: request)?.state else {
            return .unavailable
        }
        return listing.pagination
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 相同请求沿用已保存的工作集，否则以新请求替换同类工作集后再切换路由。
    private func activateWorkset(_ request: FeedRequest) {
        switchRoute(to: request)
        if case .idle = state {
            refresh(request)
        }
    }

    /// 让 `request` 成为当前路由；同类工作集属于其他请求时以新的空工作集替换。
    private func switchRoute(to request: FeedRequest) {
        if activeRequestIdentity != request {
            deactivateRoute()
            activeRequestIdentity = request
        }
        if workset(for: request) == nil {
            worksets[request.source] = FeedWorkset(request: request)
        }
    }

    private func refresh(_ request: FeedRequest) {
        switchRoute(to: request)
        updateActiveWorkset { workset in
            workset.refreshError = nil
            if case .loaded(var listing) = workset.state {
                listing.beginRefresh()
                workset.state = .loaded(listing)
            } else {
                workset.state = .loading(request)
            }
        }
        loadTask.replace { [weak self] isCurrent in
            await self?.performLoad(request, isCurrent: isCurrent)
        }
    }

    private func fail(
        request: FeedRequest,
        error: ContentApplicationError
    ) {
        deactivateRoute()
        activeRequestIdentity = request
        worksets[request.source] = FeedWorkset(
            request: request,
            state: .failed(request: request, error: error)
        )
    }

    private func performLoad(
        _ request: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard isCurrent(), activeRequestIdentity == request else { return }
            let previous = activeWorkset?.listing
            guard
                let listing = FeedListing(
                    firstPage: content,
                    for: request,
                    replacing: previous
                )
            else {
                throw ContentApplicationError.invalidResponse
            }
            updateActiveWorkset { workset in
                workset.state = .loaded(listing)
                workset.refreshError = nil
            }
            if previous?.isRefreshing == true {
                successfulRefreshGenerations[request.source, default: 0] &+= 1
            }
        } catch is CancellationError {
            guard isCurrent(), activeRequestIdentity == request else { return }
            normalizeInterruptedLoad()
        } catch {
            guard isCurrent(), activeRequestIdentity == request else { return }
            handleFailure(error as? ContentApplicationError ?? .unavailable, request: request)
        }
    }

    /// 下一页只在仍属于当前路由时并入；与已加载页不衔接的响应由 `FeedListing` 记为加载更多失败。
    private func performAppend(
        _ request: FeedRequest,
        baseRequest: FeedRequest,
        isCurrent: LatestTask.IsCurrent
    ) async {
        do {
            let content = try await useCase.execute(request)
            try Task.checkCancellation()
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            updateActiveListing { $0.append(content, for: request) }
        } catch is CancellationError {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            updateActiveListing { $0.cancelPendingWork() }
        } catch {
            guard isCurrent(), activeRequestIdentity == baseRequest else { return }
            let error = error as? ContentApplicationError ?? .unavailable
            updateActiveListing { $0.failLoadMore(error) }
            recordAuthenticationInvalidationIfNeeded(error)
        }
    }

    /// 已有内容时刷新失败保留内容、恢复刷新前的分页并给出刷新错误；否则进入失败页。
    private func handleFailure(
        _ error: ContentApplicationError,
        request: FeedRequest
    ) {
        recordAuthenticationInvalidationIfNeeded(error)
        updateActiveWorkset { workset in
            if case .loaded(var listing) = workset.state {
                listing.cancelPendingWork()
                workset.state = .loaded(listing)
                workset.refreshError = error
            } else {
                workset.state = .failed(request: request, error: error)
            }
        }
    }

    private func normalizeInterruptedLoad() {
        updateActiveWorkset { workset in
            workset.refreshError = nil
            switch workset.state {
            case .loading:
                workset.state = .idle
            case .loaded(var listing):
                listing.cancelPendingWork()
                workset.state = .loaded(listing)
            case .idle, .failed:
                break
            }
        }
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: ContentApplicationError
    ) {
        guard error.requiresAccountRevalidation else { return }
        authenticationRevalidationGeneration &+= 1
    }

    private var activeWorkset: FeedWorkset? {
        activeRequestIdentity.flatMap(workset(for:))
    }

    private func updateActiveWorkset(_ update: (inout FeedWorkset) -> Void) {
        guard let request = activeRequestIdentity, var workset = workset(for: request) else {
            return
        }
        update(&workset)
        worksets[request.source] = workset
    }

    private func updateActiveListing(_ update: (inout FeedListing) -> Void) {
        updateActiveWorkset { workset in
            guard case .loaded(var listing) = workset.state else { return }
            update(&listing)
            workset.state = .loaded(listing)
        }
    }

    private func workset(for request: FeedRequest) -> FeedWorkset? {
        guard let workset = worksets[request.source], workset.request == request else {
            return nil
        }
        return workset
    }
}

/// 一个来源的第一页请求及其状态；加载更多与刷新进行状态在已加载的 `FeedListing` 里。
private struct FeedWorkset {
    let request: FeedRequest
    var state: FeedState = .idle
    var refreshError: ContentApplicationError?

    var listing: FeedListing? {
        guard case .loaded(let listing) = state else { return nil }
        return listing
    }

    var isRefreshing: Bool {
        listing?.isRefreshing ?? false
    }
}
