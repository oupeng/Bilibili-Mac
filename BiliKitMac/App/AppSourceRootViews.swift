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
    let onSelect: (String) -> Void
    let onSubmit: () -> Void
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
            onClearFilters: onClearFilters
        )
        .navigationTitle("搜索")
        .toolbar(removing: .title)
        .searchable(
            text: $searchDraft,
            placement: searchFieldPlacement,
            prompt: "搜索 B 站视频"
        )
        .onSubmit(of: .search) {
            onSubmit()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SearchToolbarControls(
                    selection: $filterSelection,
                    onSelectOrder: onSelectOrder,
                    onApplyFilters: onApplyFilters
                )
            }
        }
    }

    private var searchFieldPlacement: SearchFieldPlacement {
        .toolbarPrincipal
    }
}

struct HistoryTabRoot: View {
    let model: WatchHistoryViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("观看历史")
            .toolbar {
                if case .signedIn = accountState {
                    ToolbarItem(placement: .primaryAction) {
                        HistoryRefreshButton(model: model)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn:
            WatchHistoryView(
                model: model,
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
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看观看历史", systemImage: "person.crop.circle")
            } description: {
                Text("观看历史只在登录期间加载，不会保存到本机。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("打开扫码登录")
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label(
                    "暂时无法确认登录状态",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            } description: {
                Text("本机登录状态没有被自动清除，请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct HistoryRefreshButton: View {
    let model: WatchHistoryViewModel

    var body: some View {
        Button {
            model.reload()
        } label: {
            Label("刷新", systemImage: "arrow.clockwise")
        }
        .disabled(model.isBusy)
    }
}

struct WatchLaterTabRoot: View {
    let model: WatchLaterViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("稍后再看")
            .toolbar {
                if case .signedIn = accountState {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.reload()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn:
            WatchLaterView(
                model: model,
                makeLoadedContent: { content in
                    HistoryNativeGridView(
                        content: LoadedHistoryContent(
                            items: content.items.map { presentation in
                                WatchHistoryCardPresentation(
                                    bvid: presentation.bvid,
                                    title: presentation.title,
                                    coverURL: presentation.coverURL,
                                    avatarURL: presentation.avatarURL,
                                    showsAvatar: presentation.showsAvatar,
                                    progressText: presentation.progressText,
                                    footerLeadingText: presentation.footerLeadingText,
                                    footerTrailingText: presentation.footerTrailingText,
                                    accessibilityLabel: presentation.accessibilityLabel
                                )
                            },
                            canLoadMore: false,
                            tailIdentity: nil,
                            isLoadingMore: false,
                            loadMore: {},
                            select: content.select
                        ),
                        scrollOffsetY: $scrollOffsetY,
                        scrollReset: $scrollReset,
                        imagePipeline: imagePipeline
                    )
                    .ignoresSafeArea(.container, edges: .top)
                },
                onSelect: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看稍后再看", systemImage: "person.crop.circle")
            } description: {
                Text("稍后再看记录需要登录 B 站账号加载。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label("暂时无法确认登录状态", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FavoritesTabRoot: View {
    let model: FavoritesViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("我的收藏")
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn(let identity):
            FavoritesView(
                model: model,
                upMID: identity.mid,
                makeLoadedContent: { content in
                    HistoryNativeGridView(
                        content: LoadedHistoryContent(
                            items: content.items.map { presentation in
                                WatchHistoryCardPresentation(
                                    bvid: presentation.bvid,
                                    title: presentation.title,
                                    coverURL: presentation.coverURL,
                                    avatarURL: presentation.avatarURL,
                                    showsAvatar: presentation.showsAvatar,
                                    progressText: "",
                                    footerLeadingText: presentation.footerLeadingText,
                                    footerTrailingText: presentation.footerTrailingText,
                                    accessibilityLabel: presentation.accessibilityLabel
                                )
                            },
                            canLoadMore: content.hasMore,
                            tailIdentity: nil,
                            isLoadingMore: content.isLoadingMore,
                            loadMore: content.loadMore,
                            select: content.selectVideo
                        ),
                        scrollOffsetY: $scrollOffsetY,
                        scrollReset: $scrollReset,
                        imagePipeline: imagePipeline
                    )
                    .ignoresSafeArea(.container, edges: .top)
                },
                onSelectVideo: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看我的收藏", systemImage: "person.crop.circle")
            } description: {
                Text("收藏夹列表需要登录 B 站账号加载。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label("暂时无法确认登录状态", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
