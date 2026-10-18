import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoCollectionUI
import SwiftUI

/// 首页推荐来源的 App 接线：呈现与原生网格在 Browse 的 `RecommendedFeedView`，这里只转交窗口级网格依赖
/// （`AppShellView` 构造的 `NativeVideoGridHostContext`）和标题。
struct RecommendedTabRoot: View {
    let title: LocalizedStringResource
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        RecommendedFeedView(
            model: model,
            gridHost: gridHost,
            onSelect: onSelect
        )
        .navigationTitle(Text(title))
    }
}

/// 热门来源的 App 接线：呈现与原生网格在 Browse 的 `PopularFeedView`，这里只转交窗口级网格依赖和标题。
struct PopularTabRoot: View {
    let title: LocalizedStringResource
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        PopularFeedView(
            model: model,
            gridHost: gridHost,
            onSelect: onSelect
        )
        .navigationTitle(Text(title))
    }
}

/// 搜索来源的 App 接线：起始页、结果呈现与原生网格在 Browse 的 `VideoSearchView`，草稿、筛选与提交在 Browse 的
/// `VideoSearchSession`；这里转交窗口级网格依赖，用热搜模型、窗口图片管线（实现热搜图标 port）与进程级搜索历史
/// 构造起始页输入，并宿主绑定会话的工具栏搜索框（AppKit）与排序、筛选控件。
struct SearchTabRoot: View {
    let title: LocalizedStringResource
    @Bindable var session: VideoSearchSession
    let model: BrowseViewModel
    let gridHost: NativeVideoGridHostContext
    let imagePipeline: NativeVideoImagePipeline
    let trendingSearchModel: TrendingSearchViewModel
    let searchHistory: SearchHistoryStore
    let searchSuggestionSource: SearchSuggestionSource
    let onSelect: (String) -> Void

    var body: some View {
        VideoSearchView(
            model: model,
            submittedSearchCriteria: session.submittedCriteria,
            hasActiveFilters: session.filterSelection.activeFilterCount > 0,
            gridHost: gridHost,
            startPageContext: startPageContext,
            onSelect: onSelect,
            onClearFilters: session.clearFilters
        )
        .navigationTitle(Text(title))
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToolbarSearchField(
                    text: $session.draft,
                    prompt: AppStrings.localized("搜索 B 站视频"),
                    history: { searchHistory.entries },
                    suggestionSource: searchSuggestionSource,
                    onSubmit: session.submit,
                    onSelectSuggestion: session.search(keyword:)
                )
                .frame(
                    minWidth: ToolbarSearchFieldLayout.minimumWidth,
                    idealWidth: ToolbarSearchFieldLayout.idealWidth,
                    maxWidth: ToolbarSearchFieldLayout.idealWidth
                )
            }
            ToolbarItemGroup(placement: .primaryAction) {
                SearchToolbarControls(
                    selection: $session.filterSelection,
                    onSelectOrder: session.selectOrder,
                    onApplyFilters: session.applyFilters
                )
            }
        }
    }

    /// 历史以读取闭包交出，只在起始页里求值，这里不读 `entries`。
    private var startPageContext: SearchStartPageContext {
        SearchStartPageContext(
            trendingModel: trendingSearchModel,
            iconLoader: imagePipeline,
            history: { searchHistory.entries },
            onSearch: session.search(keyword:),
            onRemoveHistory: { searchHistory.remove($0) },
            onClearHistory: { searchHistory.clear() }
        )
    }
}

/// 稍后再看来源的 App 接线：登录门槛、刷新、加载语义、筛选空态与原生网格在 Library 的 `WatchLaterView`，条件在
/// Library 的 `WatchLaterSession`。这里转交账户呈现状态、窗口级网格依赖、标题与打开登录页的动作，并宿主已登录时的
/// 排序菜单与筛选按钮（排在刷新之前）、工具栏尾部的紧凑搜索框（系统 `.searchable`，回车提交、清空恢复全部），以及
/// 当前条件下总数的副标题。搜索框不放工具栏正中：那是搜索来源的全局搜索框，这里只过滤本列表。
struct WatchLaterTabRoot: View {
    @Environment(\.locale) private var locale
    let title: LocalizedStringResource
    let model: WatchLaterViewModel
    @Bindable var session: WatchLaterSession
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        let content = WatchLaterView(
            model: model,
            session: session,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication,
            toolbarControls: AnyView(WatchLaterToolbarControls(session: session))
        )
        .navigationTitle(Text(title))
        .navigationSubtitle(subtitle)
        if case .signedIn = accountState {
            content
                .searchable(
                    text: $session.searchDraft,
                    placement: .toolbar,
                    prompt: Text(AppStrings.localized("搜索稍后再看", locale: locale))
                )
                .onSubmit(of: .search) {
                    session.submitSearch()
                }
        } else {
            content
        }
    }

    /// 已显示内容时是当前条件下的总数，其他时候不显示。
    private var subtitle: String {
        guard let totalCount = model.totalCount else { return "" }
        return AppStrings.localized("共 \(totalCount) 个", locale: locale)
    }
}

/// 观看历史来源的 App 接线：登录门槛、刷新、加载语义与原生网格在 Library 的 `WatchHistoryView`，这里只转交
/// 账户呈现状态、窗口级网格依赖、标题与打开登录页的动作。
struct HistoryTabRoot: View {
    let title: LocalizedStringResource
    let model: WatchHistoryViewModel
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void

    var body: some View {
        WatchHistoryView(
            model: model,
            accountState: accountState,
            gridHost: gridHost,
            onSelect: onSelect,
            onPresentAuthentication: onPresentAuthentication
        )
        .navigationTitle(Text(title))
    }
}
