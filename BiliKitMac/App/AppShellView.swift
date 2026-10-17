import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoCollectionUI
import SwiftUI

/// 描述窗口的原生 NavigationSplitView/NavigationStack 外壳，并保留来源状态与滚动位置。
///
/// 系统返回通过 path Binding 回写 coordinator，使播放停止与视觉导航保持同一事实来源；
/// SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    @Environment(\.openURL) private var openURL
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let uploaderSpaceModel: UploaderSpaceViewModel?
    let trendingSearchModel: TrendingSearchViewModel?
    let searchHistory: SearchHistoryStore?
    let searchSuggestionSource: SearchSuggestionSource?
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    let commentShortLinks: CommentShortLinkResolution
    let commentImageSaver: NativeCommentImageSaver
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    let imagePipeline: NativeVideoImagePipeline
    @Binding var isAuthenticationPresented: Bool
    @Binding var searchFilterSelection: SearchFilterSelection
    let submittedSearchCriteria: VideoSearchCriteria?
    let onSubmitSearch: () -> Void
    let onSearchKeyword: (String) -> Void
    let onSelectSearchOrder: (VideoSearchOrder) -> Void
    let onApplySearchFilters: (SearchFilterSelection) -> Void
    let onClearSearchFilters: () -> Void
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var gridScroll = SourceGridScrollStates()
    @State private var commentImagePreview: NativeCommentImagePreviewRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var navigationCoordinator = navigationCoordinator

        NavigationSplitView(columnVisibility: guardedColumnVisibility) {
            // 侧栏 = 底层（导航或播放详情）+ 可选的上下文层（UP 主空间）。两层并列叠放，各自按安全区布局；
            // 上下文层打开时底层保留状态（关闭后评论位置还在），但不可见、不可点、对辅助功能隐藏。
            ZStack {
                Group {
                    if navigationCoordinator.currentPlaybackBVID != nil {
                        playbackSidebar
                    } else {
                        AppNavigationSidebar(
                            selection: $navigationCoordinator.selectedTab,
                            accountState: authenticationModel.accountPresentationState,
                            onPresentAuthentication: {
                                isAuthenticationPresented = true
                            }
                        )
                    }
                }
                .id(sidebarContextID)
                .opacity(isSidebarContextOpen ? 0 : 1)
                .allowsHitTesting(!isSidebarContextOpen)
                .accessibilityHidden(isSidebarContextOpen)

                // 只给上下文层自己的插入／移除加动画；底层立即隐藏，不参与这次 transaction，
                // 否则底层的 AppKit 集合视图会把布局变化也做成动画而跳动。
                ZStack { sidebarContextLayer }
                    .animation(
                        reduceMotion
                            ? nil
                            : .snappy(duration: UploaderSpaceGeometry.layerTransitionDuration),
                        value: isSidebarContextOpen
                    )
            }
            .navigationSplitViewColumnWidth(
                min: sidebarMinimumWidth,
                ideal: sidebarIdealWidth,
                max: sidebarMaximumWidth
            )
        } detail: {
            NavigationStack(path: guardedPlaybackPath) {
                selectedSourceRoot
                    .navigationDestination(
                        for: PlaybackDestination.self
                    ) { _ in
                        PlaybackDestinationView(
                            model: videoModel,
                            danmakuModel: danmakuModel,
                            playerContent: playerContent,
                            imagePipeline: imagePipeline,
                            onRetry: retryPlayback,
                            onSelectRelatedVideo:
                                navigationCoordinator.openPlayback
                        )
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbarVisibility(
            isCommentImagePreviewPresented ? .hidden : .automatic,
            for: .windowToolbar
        )
        .frame(minWidth: 760, minHeight: 560)
        .overlay {
            if let commentImagePreview,
                commentImagePreview.bvid
                    == navigationCoordinator.currentPlaybackBVID
            {
                NativeCommentImagePreviewView(
                    request: commentImagePreview,
                    imagePipeline: imagePipeline,
                    resolveURL: commentAssetURLResolver,
                    imageSaver: commentImageSaver,
                    onDismiss: {
                        dismissCommentImagePreview(restoringFocus: true)
                    }
                )
            }
        }
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onChange(of: submittedSearchCriteria) { previousCriteria, criteria in
            guard previousCriteria != criteria else { return }
            scrollToTop(.search)
        }
        .onChange(of: successfulRefreshGenerations) { previousGenerations, generations in
            for (tab, generation) in generations where previousGenerations[tab] != generation {
                scrollToTop(tab)
            }
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            // 账户变化会替换每个来源的内容（Browse 丢弃全部工作集，历史随账户重载），所有网格都回到顶部。
            for tab in AppTab.allCases {
                scrollToTop(tab)
            }
        }
        .onChange(of: navigationCoordinator.currentPlaybackBVID) {
            previousBVID,
            currentBVID in
            guard previousBVID != currentBVID else { return }
            dismissCommentImagePreview(restoringFocus: false)
        }
    }

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
    }

    private var isCommentImagePreviewPresented: Bool {
        guard let commentImagePreview else { return false }
        return commentImagePreview.bvid
            == navigationCoordinator.currentPlaybackBVID
    }

    private var guardedColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columnVisibility },
            set: { nextVisibility in
                guard !isCommentImagePreviewPresented else { return }
                columnVisibility = nextVisibility
            }
        )
    }

    private var guardedPlaybackPath: Binding<[PlaybackDestination]> {
        Binding(
            get: { navigationCoordinator.playbackPath },
            set: { path in
                guard !isCommentImagePreviewPresented else { return }
                navigationCoordinator.playbackPath = path
            }
        )
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    /// 各来源最近一次刷新成功的代次；某来源前进时只把它自己的网格滚回顶部。
    private var successfulRefreshGenerations: [AppTab: UInt64] {
        [
            .home: browseModel.successfulRefreshGeneration(for: .recommendation),
            .popular: browseModel.successfulRefreshGeneration(for: .popular),
            .search: browseModel.successfulRefreshGeneration(for: .search),
            .history: historyModel.successfulReloadGeneration
        ]
    }

    private func gridScrollBinding(_ tab: AppTab) -> Binding<SourceGridScrollState> {
        $gridScroll[dynamicMember: \.[tab]]
    }

    /// 回顶只发 reset 请求：已挂载的网格立即滚到 0 并把位置同步回 offset binding，
    /// 未挂载的网格在下次挂载时消费同一请求。
    private func scrollToTop(_ tabs: AppTab...) {
        for tab in tabs {
            gridScroll[tab].reset.request()
        }
    }

    private var playbackSidebar: some View {
        NativePlaybackSidebarView(
            model: videoModel,
            commentsModel: commentsModel,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: imagePipeline,
            onRetry: retryPlayback,
            onSelectPlayback: { bvid, preferredCID in
                navigationCoordinator.openPlayback(
                    PlaybackSelectionIntent(
                        bvid: bvid,
                        preferredCID: preferredCID
                    )
                )
            },
            onOpenCommentLink: { openCommentLink(commentLinkRouter($0)) },
            onOpenCommentPictures: openCommentPictures,
            onOpenUploaderSpace: uploaderSpaceModel.map { model in
                { owner in model.open(owner: owner) }
            },
            isObscured: isSidebarContextOpen
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var isSidebarContextOpen: Bool {
        uploaderSpaceModel?.owner != nil
    }

    @ViewBuilder
    private var sidebarContextLayer: some View {
        if let uploaderSpaceModel, uploaderSpaceModel.owner != nil {
            UploaderSpaceSidebarView(
                model: uploaderSpaceModel,
                currentBVID: navigationCoordinator.currentPlaybackBVID,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlaybackFromSidebarContext,
                onLogin: { isAuthenticationPresented = true }
            )
            .transition(
                reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    // 浏览态与播放态共用一列：ideal 只在首次布局生效，切换状态时宽度被夹进新范围，
    // 因此进入播放时侧栏宽度等于播放态最小值；更宽由用户自行拖动。
    private var sidebarMinimumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 300 : 520
    }

    private var sidebarIdealWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 520
    }

    private var sidebarMaximumWidth: CGFloat {
        navigationCoordinator.currentPlaybackBVID == nil ? 320 : 720
    }

    /// 评论正文链接：视频（含分 P）在应用内播放，空间链接在侧栏空间层打开，其余交给系统浏览器。
    ///
    /// @ 提及在侧栏内已进入空间，到这里只剩没有空间功能时的网页回退。短链先由窗口级 owner 解析，
    /// 解析出的路由再走这里一次，解析不出时打开原短链。时间戳与指向正在播放分 P 的 `t=` 直接跳转，
    /// 不经过导航去重，同一个时间点可以反复点。
    private func openCommentLink(_ route: CommentLinkRoute?) {
        switch route {
        case .playback(let intent):
            if let seconds = AppWindowOwner.inPlaceStartSeconds(
                for: intent,
                currentPlaybackBVID: navigationCoordinator.currentPlaybackBVID,
                videoModel: videoModel
            ) {
                seekPlayback(intent.bvid, seconds)
            } else {
                navigationCoordinator.openPlayback(intent)
            }
        case .seek(let seconds):
            if let bvid = navigationCoordinator.currentPlaybackBVID {
                seekPlayback(bvid, seconds)
            }
        case .space(let memberID, let webFallback):
            if let uploaderSpaceModel {
                uploaderSpaceModel.open(ownerID: memberID)
            } else if let webFallback {
                openURL(webFallback)
            }
        case .web(let url):
            openURL(url)
        case .shortLink(let resolve, let webFallback):
            commentShortLinks.start(resolve) { resolved in
                openCommentLink(resolved ?? webFallback.map(CommentLinkRoute.web))
            }
        case nil:
            break
        }
    }

    private func retryPlayback() {
        AppWindowOwner.retryPlayback(coordinator: navigationCoordinator, videoModel: videoModel)
    }

    private func openCommentPictures(
        _ gallery: NativePlaybackCommentPictureGallery
    ) {
        guard let bvid = navigationCoordinator.currentPlaybackBVID,
            !gallery.references.isEmpty
        else { return }
        commentImagePreview = NativeCommentImagePreviewRequest(
            bvid: bvid,
            references: gallery.references,
            selectedIndex: gallery.selectedIndex,
            restoreFocus: gallery.restoreFocus
        )
    }

    private func dismissCommentImagePreview(restoringFocus: Bool) {
        guard let request = commentImagePreview else { return }
        commentImagePreview = nil
        guard restoringFocus else { return }
        Task { @MainActor in
            await Task.yield()
            request.restoreFocus()
        }
    }

    @ViewBuilder
    private var selectedSourceRoot: some View {
        switch navigationCoordinator.selectedTab {
        case .home:
            RecommendedTabRoot(
                model: browseModel,
                scrollOffsetY: gridScrollBinding(.home).offsetY,
                scrollReset: gridScrollBinding(.home).reset,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlayback
            )
        case .search:
            SearchTabRoot(
                filterSelection: $searchFilterSelection,
                model: browseModel,
                searchDraft: Binding(
                    get: { navigationCoordinator.searchDraft },
                    set: { navigationCoordinator.searchDraft = $0 }
                ),
                submittedSearchCriteria: submittedSearchCriteria,
                scrollOffsetY: gridScrollBinding(.search).offsetY,
                scrollReset: gridScrollBinding(.search).reset,
                imagePipeline: imagePipeline,
                trendingSearchModel: trendingSearchModel,
                searchHistory: searchHistory,
                searchSuggestionSource: searchSuggestionSource,
                onSelect: navigationCoordinator.openPlayback,
                onSubmit: onSubmitSearch,
                onSearchKeyword: onSearchKeyword,
                onSelectOrder: onSelectSearchOrder,
                onApplyFilters: onApplySearchFilters,
                onClearFilters: onClearSearchFilters
            )
        case .popular:
            PopularTabRoot(
                model: browseModel,
                scrollOffsetY: gridScrollBinding(.popular).offsetY,
                scrollReset: gridScrollBinding(.popular).reset,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlayback
            )
        case .history:
            HistoryTabRoot(
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                scrollOffsetY: gridScrollBinding(.history).offsetY,
                scrollReset: gridScrollBinding(.history).reset,
                imagePipeline: imagePipeline,
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        }
    }
}

/// 单个来源网格的滚动位置与回顶请求。
private struct SourceGridScrollState {
    var offsetY: CGFloat = 0
    var reset = NativeVideoGridScrollResetState()
}

/// 四个来源各自独立的网格滚动状态；来源之间不共享可被互相覆盖的位置。
private struct SourceGridScrollStates {
    private var states: [AppTab: SourceGridScrollState] = [:]

    subscript(tab: AppTab) -> SourceGridScrollState {
        get { states[tab] ?? SourceGridScrollState() }
        set { states[tab] = newValue }
    }
}

private struct PlaybackDestinationView: View {
    let model: VideoViewModel
    let danmakuModel: DanmakuControlsViewModel
    let playerContent: AnyView
    let imagePipeline: NativeVideoImagePipeline
    let onRetry: () -> Void
    let onSelectRelatedVideo: (String) -> Void

    var body: some View {
        VideoPlaybackView(
            model: model,
            danmakuModel: danmakuModel,
            onRetry: onRetry,
            onSelectRelatedVideo: onSelectRelatedVideo,
            makeRelatedContent: {
                contentIdentity,
                presentations,
                onSelect in
                RelatedNativeShelfView(
                    contentIdentity: contentIdentity,
                    presentations: presentations,
                    imagePipeline: imagePipeline,
                    onSelect: onSelect
                )
            }
        ) {
            playerContent
        }
        // 播放页压在来源页（NavigationStack 根）之上，根页面为保留状态仍在渲染；macOS 不为压栈
        // 页面绘制底色，必须自铺不透明窗口背景，并延伸到工具栏与侧栏下方。
        .background {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .navigationTitle("播放")
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}
