import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct RecommendedTabRoot: View {
    let model: BrowseViewModel
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void

    var body: some View {
        RecommendedFeedView(
            model: model,
            makeLoadedContent: { content in
                RecommendedNativeGridView(
                    content: content,
                    scrollOffsetY: $scrollOffsetY,
                    scrollReset: $scrollReset,
                    imagePipeline: imagePipeline
                )
                .ignoresSafeArea(.container, edges: .top)
            },
            onSelect: onSelect
        )
        .navigationTitle("首页")
    }
}

struct PopularTabRoot: View {
    let model: BrowseViewModel
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            makeLoadedContent: { content in
                PopularNativeGridView(
                    content: content,
                    scrollOffsetY: $scrollOffsetY,
                    scrollReset: $scrollReset,
                    imagePipeline: imagePipeline
                )
                .ignoresSafeArea(.container, edges: .top)
            },
            onSelect: onSelect
        )
        .navigationTitle("热门")
    }
}

struct SearchTabRoot: View {
    @Binding var filterSelection: SearchFilterSelection
    let model: BrowseViewModel
    @Binding var searchDraft: String
    let submittedSearchCriteria: VideoSearchCriteria?
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let trendingSearchModel: TrendingSearchViewModel?
    let searchHistory: SearchHistoryStore?
    let searchSuggestionSource: SearchSuggestionSource?
    let onSelect: (String) -> Void
    let onSubmit: () -> Void
    let onSearchKeyword: (String) -> Void
    let onSelectOrder: (VideoSearchOrder) -> Void
    let onApplyFilters: (SearchFilterSelection) -> Void
    let onClearFilters: () -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            submittedSearchCriteria: submittedSearchCriteria,
            hasActiveFilters: filterSelection.activeFilterCount > 0,
            makeLoadedContent: { content in
                SearchNativeGridView(
                    content: content,
                    scrollOffsetY: $scrollOffsetY,
                    scrollReset: $scrollReset,
                    imagePipeline: imagePipeline
                )
                .ignoresSafeArea(.container, edges: .top)
            },
            onSelect: onSelect,
            onClearFilters: onClearFilters,
            startContent: {
                if let trendingSearchModel {
                    SearchStartView(
                        history: searchHistory?.entries ?? [],
                        trendingModel: trendingSearchModel,
                        onSearch: onSearchKeyword,
                        onRemoveHistory: { searchHistory?.remove($0) },
                        onClearHistory: { searchHistory?.clear() },
                        makeTrendingIcon: { url in
                            TrendingSearchIconView(url: url, imagePipeline: imagePipeline)
                        }
                    )
                }
            }
        )
        .navigationTitle("搜索")
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarSearchField(
                    text: $searchDraft,
                    prompt: AppStrings.localized("搜索 B 站视频"),
                    history: { searchHistory?.entries ?? [] },
                    suggestionSource: searchSuggestionSource,
                    onSubmit: onSubmit,
                    onSelectSuggestion: onSearchKeyword
                )
                .frame(
                    minWidth: ToolbarSearchFieldLayout.minimumWidth,
                    idealWidth: ToolbarSearchFieldLayout.idealWidth,
                    maxWidth: ToolbarSearchFieldLayout.idealWidth
                )
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SearchToolbarControls(
                    selection: $filterSelection,
                    onSelectOrder: onSelectOrder,
                    onApplyFilters: onApplyFilters
                )
            }
        }
    }
}

/// 观看历史来源的 App 接线：登录门槛、刷新与加载语义在 Library 的 `WatchHistoryView`，这里只提供原生网格、
/// 标题与打开登录页的动作。
struct HistoryTabRoot: View {
    let model: WatchHistoryViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        WatchHistoryView(
            model: model,
            accountState: accountState,
            makeLoadedContent: { content in
                HistoryNativeGridView(
                    content: content,
                    scrollOffsetY: $scrollOffsetY,
                    scrollReset: $scrollReset,
                    imagePipeline: imagePipeline
                )
                .ignoresSafeArea(.container, edges: .top)
            },
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication
        )
        .navigationTitle("观看历史")
    }
}
