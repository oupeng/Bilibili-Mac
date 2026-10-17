import BiliApplication
import BiliModels

/// 一个 Feed 来源已加载的累积条目与分页状态；分页游标是该来源的下一页请求。
///
/// 只把远端页适配为 `VideoListPage` 并校验响应属于所请求的页；去重、上限、无进展停止与尾标由
/// `PagedVideoList` 负责，请求、Task 与工作集由 `BrowseViewModel` 拥有。
enum FeedListing: Sendable, Equatable {
    case recommendation(RecommendationListing)
    case popular(PagedVideoList<PopularVideo, FeedRequest>)
    case search(query: String, PagedVideoList<SearchVideo, FeedRequest>)

    /// 首次加载或刷新成功的第一页。
    ///
    /// `previous` 是同一工作集刷新前的列表，沿用它让尾标计数单调递增。响应不属于该请求时返回 nil，
    /// 调用方按无效响应处理。
    init?(
        firstPage content: FeedContent,
        for request: FeedRequest,
        replacing previous: FeedListing?
    ) {
        guard request.accepts(content) else { return nil }
        switch (request, content) {
        case (.recommendation, .recommendation(let page)):
            self = .recommendation(RecommendationListing(firstPage: page))
        case (.popular, .popular(let page)):
            var list = previous?.popularList ?? PagedVideoList(stallPolicy: .stop)
            list.replaceFirstPage(page.videoPage, bvid: \.bvid)
            self = .popular(list)
        case (.search(let searchRequest), .search(let query, let page)):
            var list = previous?.searchList ?? PagedVideoList(stallPolicy: .stop)
            list.replaceFirstPage(page.videoPage(criteria: searchRequest.criteria), bvid: \.bvid)
            self = .search(query: query, list)
        default:
            return nil
        }
    }

    /// 近尾分页与底部胶囊的投影：尾标只在仍可自动加载时给出。
    var pagination: FeedPaginationPresentation {
        switch self {
        case .recommendation(let listing):
            FeedPaginationPresentation(
                tailIdentity: listing.tailIdentity,
                isLoadingMore: listing.isLoadingMore,
                loadMoreError: listing.loadMoreError
            )
        case .popular(let list): FeedPaginationPresentation(list)
        case .search(_, let list): FeedPaginationPresentation(list)
        }
    }

    var isRefreshing: Bool {
        switch self {
        case .recommendation(let listing): listing.isRefreshing
        case .popular(let list): list.isRefreshing
        case .search(_, let list): list.isRefreshing
        }
    }

    /// 返回应请求的下一页；正在加载、原地刷新或已到底时为 nil。
    ///
    /// 失败后的重试也走这里，请求同一页。
    mutating func beginLoadMore() -> FeedRequest? {
        switch self {
        case .recommendation(var listing):
            defer { self = .recommendation(listing) }
            return listing.beginLoadMore()
        case .popular(var list):
            defer { self = .popular(list) }
            return list.beginLoadMore()
        case .search(let query, var list):
            defer { self = .search(query: query, list) }
            return list.beginLoadMore()
        }
    }

    /// 并入 `request` 对应的下一页；响应不属于该请求或与已加载页不衔接时记为无效响应的加载失败。
    mutating func append(_ content: FeedContent, for request: FeedRequest) {
        guard request.accepts(content) else {
            failLoadMore(.invalidResponse)
            return
        }
        switch (self, request, content) {
        case (
            .recommendation(var listing),
            .recommendation(let continuation?),
            .recommendation(let page)
        ):
            listing.apply(page, requested: continuation)
            self = .recommendation(listing)
        case (.popular(var list), .popular, .popular(let page)):
            list.apply(page.videoPage, requested: request, bvid: \.bvid)
            self = .popular(list)
        case (.search(let query, var list), .search(let searchRequest), .search(_, let page)):
            list.apply(
                page.videoPage(criteria: searchRequest.criteria),
                requested: request,
                bvid: \.bvid
            )
            self = .search(query: query, list)
        default:
            failLoadMore(.invalidResponse)
        }
    }

    mutating func failLoadMore(_ error: ContentApplicationError) {
        switch self {
        case .recommendation(var listing):
            listing.failLoadMore(error)
            self = .recommendation(listing)
        case .popular(var list):
            list.failLoadMore(error)
            self = .popular(list)
        case .search(let query, var list):
            list.failLoadMore(error)
            self = .search(query: query, list)
        }
    }

    /// 取消进行中的加载更多与原地刷新，分页回到开始前的样子；路由停用或请求被外部中断时调用。
    mutating func cancelPendingWork() {
        switch self {
        case .recommendation(var listing):
            listing.cancelPendingWork()
            self = .recommendation(listing)
        case .popular(var list):
            list.cancelLoadMore(requiringManualContinue: false)
            list.restoreAfterFailedRefresh()
            self = .popular(list)
        case .search(let query, var list):
            list.cancelLoadMore(requiringManualContinue: false)
            list.restoreAfterFailedRefresh()
            self = .search(query: query, list)
        }
    }

    mutating func beginRefresh() {
        switch self {
        case .recommendation(var listing):
            listing.beginRefresh()
            self = .recommendation(listing)
        case .popular(var list):
            list.beginRefresh()
            self = .popular(list)
        case .search(let query, var list):
            list.beginRefresh()
            self = .search(query: query, list)
        }
    }

    private var popularList: PagedVideoList<PopularVideo, FeedRequest>? {
        guard case .popular(let list) = self else { return nil }
        return list
    }

    private var searchList: PagedVideoList<SearchVideo, FeedRequest>? {
        guard case .search(_, let list) = self else { return nil }
        return list
    }
}

/// 推荐的累积页与加载更多状态。
///
/// 无新增或达到条目上限时把 `nextContinuation` 收为 nil 以停止翻页；尾标取当前批次的 `freshIndex`，
/// 只在并入新一批时变化。
struct RecommendationListing: Sendable, Equatable {
    private var page: RecommendationPage
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: ContentApplicationError?
    private(set) var isRefreshing = false

    init(firstPage: RecommendationPage) {
        let first = [].appendingVideoPage(firstPage.videos, \.bvid)
        page = RecommendationPage(
            videos: first.items,
            continuation: firstPage.continuation,
            nextContinuation: first.continuesPagination ? firstPage.nextContinuation : nil
        )
    }

    var items: [RecommendedVideo] { page.videos }

    var tailIdentity: UInt64? {
        guard page.nextContinuation != nil, !page.videos.isEmpty, loadMoreError == nil,
            !isRefreshing
        else { return nil }
        return UInt64(page.continuation.freshIndex)
    }

    mutating func beginLoadMore() -> FeedRequest? {
        guard !isLoadingMore, !isRefreshing, let next = page.nextContinuation,
            !page.videos.isEmpty
        else { return nil }
        isLoadingMore = true
        loadMoreError = nil
        return .recommendation(continuation: next)
    }

    mutating func apply(
        _ response: RecommendationPage,
        requested continuation: RecommendationContinuation
    ) {
        guard isLoadingMore, page.nextContinuation == continuation else {
            failLoadMore(.invalidResponse)
            return
        }
        isLoadingMore = false
        let append = page.videos.appendingVideoPage(response.videos, \.bvid)
        page = RecommendationPage(
            videos: append.items,
            continuation: response.continuation,
            nextContinuation: append.continuesPagination ? response.nextContinuation : nil
        )
    }

    mutating func failLoadMore(_ error: ContentApplicationError) {
        isLoadingMore = false
        loadMoreError = error
    }

    mutating func cancelPendingWork() {
        isLoadingMore = false
        isRefreshing = false
    }

    mutating func beginRefresh() {
        isLoadingMore = false
        loadMoreError = nil
        isRefreshing = true
    }
}

extension FeedPaginationPresentation {
    fileprivate init<Item>(_ list: PagedVideoList<Item, FeedRequest>) {
        self.init(
            tailIdentity: list.tailIdentity,
            isLoadingMore: list.isLoadingMore,
            loadMoreError: list.loadMoreError
        )
    }
}

extension FeedRequest {
    /// 响应属于这次请求；首次加载与加载更多共用。
    ///
    /// 推荐批次、热门页码与页大小、搜索关键词与页码都与请求一致，且搜索页码不超过总页数（第一页另要求结果数
    /// 非负，并允许“0 页且没有条目”的空结果）。
    fileprivate func accepts(_ content: FeedContent) -> Bool {
        switch (self, content) {
        case (.recommendation(let requestedContinuation), .recommendation(let page)):
            page.continuation
                == (requestedContinuation ?? RecommendationContinuation(freshIndex: 1))
        case (.popular(let requestedPage, let requestedSize), .popular(let page)):
            page.pageNumber == requestedPage && page.pageSize == requestedSize
        case (.search(let request), .search(let responseQuery, let page)):
            responseQuery == request.criteria.query
                && page.pageNumber == request.page
                && page.pageSize == request.criteria.pageSize
                && (request.page > 1 || page.totalResults >= 0)
                && (page.totalPages >= page.pageNumber
                    || (request.page == 1 && page.totalPages == 0 && page.videos.isEmpty))
        default:
            false
        }
    }
}

extension PopularPage {
    /// 热门按页码翻页：还有更多时下一页请求是同页大小的下一页码。
    fileprivate var videoPage: VideoListPage<PopularVideo, FeedRequest> {
        VideoListPage(
            items: videos,
            nextCursor: hasMore ? .popular(page: pageNumber + 1, pageSize: pageSize) : nil
        )
    }
}

extension SearchPage {
    /// 搜索按页码翻页：未到总页数时下一页请求沿用同一搜索条件。
    fileprivate func videoPage(
        criteria: VideoSearchCriteria
    ) -> VideoListPage<SearchVideo, FeedRequest> {
        VideoListPage(
            items: videos,
            nextCursor: pageNumber < totalPages
                ? .search(VideoSearchRequest(criteria: criteria, page: pageNumber + 1))
                : nil
        )
    }
}
