import BiliApplication
import BiliModels
import BiliUI
import SwiftUI

public struct VideoSearchView<LoadedContent: View, StartContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let model: BrowseViewModel
    private let submittedSearchCriteria: VideoSearchCriteria?
    private let hasActiveFilters: Bool
    private let makeLoadedContent: (LoadedFeedContent<SearchVideoCardPresentation>) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onClearFilters: () -> Void
    private let startContent: () -> StartContent

    /// `startContent` 在尚未提交搜索时显示（搜索历史与热搜）。
    public init(
        model: BrowseViewModel,
        submittedSearchCriteria: VideoSearchCriteria?,
        hasActiveFilters: Bool,
        makeLoadedContent:
            @escaping (LoadedFeedContent<SearchVideoCardPresentation>) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onClearFilters: @escaping () -> Void,
        @ViewBuilder startContent: @escaping () -> StartContent
    ) {
        self.model = model
        self.submittedSearchCriteria = submittedSearchCriteria
        self.hasActiveFilters = hasActiveFilters
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
        self.onClearFilters = onClearFilters
        self.startContent = startContent
    }

    public var body: some View {
        ZStack {
            results
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
    }

    private var visualPhase: LoadingVisualPhase {
        guard let submittedSearchCriteria else { return .idle }
        let request = FeedRequest.search(
            VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
        )
        switch model.presentation(for: request).state {
        case .idle, .loading:
            return .loading
        case .loaded(.search(_, let page)) where page.videos.isEmpty:
            return .empty
        case .loaded(.search(_, _)):
            return .content
        case .failed(request: .search, error: _):
            return .failure
        default:
            return .transitioning
        }
    }

    @ViewBuilder
    private var results: some View {
        if let submittedSearchCriteria {
            let request = FeedRequest.search(
                VideoSearchRequest(criteria: submittedSearchCriteria, page: 1)
            )
            searchResults(for: request)
        } else {
            startContent()
        }
    }

    @ViewBuilder
    private func searchResults(for request: FeedRequest) -> some View {
        let presentation = model.presentation(for: request)
        switch presentation.state {
        case .idle, .loading:
            let query = request.searchQuery ?? ""
            SearchResultsSkeleton(query: query)
        case .loaded(.search(let query, let page)) where page.videos.isEmpty:
            VStack(spacing: 12) {
                ContentUnavailableView.search(text: query)
                if hasActiveFilters {
                    Button(
                        BrowseFeatureStrings.localized("清除筛选", locale: locale),
                        action: onClearFilters
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                refreshStatus(presentation)
            }
        case .loaded(.search(_, let page)):
            loadedResults(criteria: request.searchCriteria, page: page)
                .overlay(alignment: .top) {
                    refreshStatus(presentation)
                }
        case .failed(request: .search, let error):
            BrowseFailureView(
                error: error,
                retry: { model.retry(request) }
            )
        default:
            startContent()
        }
    }

    /// 同条件再次提交是原地刷新；结果为空时也要显示刷新中与刷新失败。
    private func refreshStatus(_ presentation: FeedPresentation) -> some View {
        RefreshStatusCapsule(
            isRefreshing: presentation.isRefreshing,
            refreshingLabel: BrowseFeatureStrings.localized(
                "正在刷新搜索结果",
                locale: locale
            ),
            errorMessage: presentation.refreshError.map {
                ContentFailureText.message(for: $0, locale: locale)
            }
        )
    }

    private func loadedResults(
        criteria: VideoSearchCriteria?,
        page: SearchPage
    ) -> some View {
        let pagination =
            criteria.map {
                model.pagination(for: .search(VideoSearchRequest(criteria: $0, page: 1)))
            } ?? .unavailable
        return makeLoadedContent(
            LoadedFeedContent(
                items: page.videos.map { SearchVideoCardPresentation(video: $0, locale: locale) },
                canLoadMore: pagination.canLoadMore,
                tailIdentity: pagination.tailIdentity,
                isLoadingMore: pagination.isLoadingMore,
                loadMore: { model.loadMore(.search) },
                select: onSelect
            )
        )
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(
                pagination.overlayStatus(
                    loadingMoreLabel: BrowseFeatureStrings.localized("正在加载更多搜索结果", locale: locale),
                    locale: locale,
                    retry: { model.retryLoadMore(.search) }
                )
            )
        }
    }
}

private struct SearchResultsSkeleton: View {
    let query: String

    var body: some View {
        VideoCardGridSkeleton(
            loadingLabel: BrowseFeatureStrings.localized("正在搜索“\(query)”")
        )
    }
}

extension FeedRequest {
    fileprivate var searchQuery: String? {
        searchCriteria?.query
    }

    fileprivate var searchCriteria: VideoSearchCriteria? {
        guard case .search(let request) = self else { return nil }
        return request.criteria
    }
}
