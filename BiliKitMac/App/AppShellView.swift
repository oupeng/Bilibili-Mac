import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 描述窗口的原生 NavigationSplitView/NavigationStack 外壳，并保留来源状态与滚动位置。
///
/// 系统返回通过 path Binding 回写 coordinator，使播放停止与视觉导航保持同一事实来源；
/// SwiftUI `body` 与普通样式 modifier 不承担资源生命周期。
struct AppShellView: View {
    @Environment(\.openURL) private var openURL
    let navigationCoordinator: AppNavigationCoordinator
    let sources: AppSources
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let watchLaterModel: WatchLaterViewModel
    let watchLaterSession: WatchLaterSession
    let historyModel: WatchHistoryViewModel
    let favoriteFolderList: FavoriteFolderListModel
    let favoriteFolders: FavoriteFolderViewModel
    let trendingSearchModel: TrendingSearchViewModel
    let searchSession: VideoSearchSession
    let searchHistory: SearchHistoryStore
    let searchSuggestionSource: SearchSuggestionSource
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    let commentShortLinks: CommentShortLinkResolution
    /// 窗口的评论图片预览面板；换视频与退出播放时关闭，关窗时由窗口组装关闭。
    let commentImagePreview: NativeCommentImagePreviewPresenter
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    let imagePipeline: NativeVideoImagePipeline
    /// 窗口的账户写入：经环境交给各来源的卡片菜单，结果胶囊盖在主区底部。
    let accountWrites: AccountWriteCoordinator
    @Binding var isAuthenticationPresented: Bool
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var gridScroll = SourceGridScrollStates()
    /// 侧栏「收藏夹」组是否展开；只在窗口内存里，默认展开。
    ///
    /// 放在这里而不是侧栏里：进入、退出播放时导航侧栏会重建。
    @State private var isFavoritesExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // 侧栏 = 底层（导航或播放详情）+ 可选的上下文层（UP 主空间）。两层并列叠放，
            // 各自按安全区布局；上下文层打开时底层保留状态（关闭后评论位置还在），但不可见、
            // 不可点、对辅助功能隐藏。播放详情是 AppKit，另经 `isObscured` 设 `isHidden`：
            // 只设透明度与 hit testing 管不到 cursor rect 和 tracking area。
            ZStack {
                Group {
                    if navigationCoordinator.currentPlaybackBVID != nil {
                        playbackSidebar
                    } else {
                        AppNavigationSidebar(
                            sections: sources.sections,
                            selection: sidebarSelection,
                            favoriteFolderList: favoriteFolderList,
                            isFavoritesExpanded: $isFavoritesExpanded,
                            accountScope: historyAccountScope,
                            accountState: authenticationModel.accountPresentationState,
                            imagePipeline: imagePipeline,
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
            NavigationStack(path: Bindable(navigationCoordinator).playbackPath) {
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
            .overlay(alignment: .bottom) {
                AccountWriteStatusOverlay(accountWrites: accountWrites)
            }
        }
        // 来源网格、相关推荐横排与它们的卡片菜单都在这棵树里；写入口只转发意图，门槛与请求在 `AccountWriteCoordinator`。
        .environment(\.videoCardAccountWriting, accountWriting)
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, minHeight: 560)
        .sheet(isPresented: $isAuthenticationPresented) {
            AuthenticationView(model: authenticationModel)
        }
        .onChange(of: searchSession.submittedCriteria) { previousCriteria, criteria in
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
            // 账户变化会替换每个来源的内容（Browse 丢弃全部工作集，稍后再看、观看历史与收藏夹随账户重载），所有网格都
            // 回到顶部。
            for tab in AppTab.allCases {
                scrollToTop(tab)
            }
        }
        .onChange(of: navigationCoordinator.currentPlaybackBVID) {
            previousBVID,
            currentBVID in
            guard previousBVID != currentBVID else { return }
            commentImagePreview.playbackDidChange(to: currentBVID)
        }
    }

    /// 卡片菜单的账户写入口：门槛在菜单构造时求值，动作转给窗口的写入协调者。
    private var accountWriting: VideoCardAccountWriting {
        let accountWrites = accountWrites
        return VideoCardAccountWriting(
            isAvailable: { accountWrites.isWritable },
            addToWatchLater: { accountWrites.addToWatchLater(bvid: $0) },
            removeFromWatchLater: { accountWrites.removeFromWatchLater(bvid: $0) }
        )
    }

    /// 侧栏的选择值：读写都经来源描述映射，选中的条目记在来源自己的模型里，侧栏重建后照样恢复高亮。
    private var sidebarSelection: Binding<AppSidebarSelection> {
        Binding(
            get: { sources.sidebarSelection(for: navigationCoordinator.selectedTab) },
            set: { sources.select($0, in: navigationCoordinator) }
        )
    }

    private var sidebarContextID: String {
        navigationCoordinator.currentPlaybackBVID == nil
            ? "navigation"
            : "playback"
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    /// 各来源内容整体替换的代次（语义见 `AppSourceDescriptor.refreshGeneration`）；某来源前进时只把它自己的网格
    /// 滚回顶部。
    private var successfulRefreshGenerations: [AppTab: UInt64] {
        Dictionary(
            uniqueKeysWithValues: sources.ordered.map { ($0.id, $0.refreshGeneration()) }
        )
    }

    /// 某个来源网格的窗口级依赖：本视图持有的滚动位置与回顶请求，加上窗口图片管线。
    private func gridHost(_ tab: AppTab) -> NativeVideoGridHostContext {
        let scroll = $gridScroll[dynamicMember: \.[tab]]
        return NativeVideoGridHostContext(
            scrollOffsetY: scroll.offsetY,
            scrollReset: scroll.reset,
            imageLoader: imagePipeline
        )
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
            onOpenCommentLink: { commentLinkOpener.open(commentLinkRouter($0)) },
            onOpenCommentPictures: openCommentPictures,
            onOpenUploaderSpace: { navigationCoordinator.openUploaderSpace(owner: $0) },
            isObscured: isSidebarContextOpen
        )
        .ignoresSafeArea(.container, edges: .top)
    }

    private var isSidebarContextOpen: Bool {
        navigationCoordinator.isSidebarContextOpen
    }

    @ViewBuilder
    private var sidebarContextLayer: some View {
        if isSidebarContextOpen {
            UploaderSpaceSidebarView(
                model: navigationCoordinator.uploaderSpace,
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

    private var commentLinkOpener: CommentLinkOpener {
        CommentLinkOpener(
            navigationCoordinator: navigationCoordinator,
            videoModel: videoModel,
            shortLinks: commentShortLinks,
            seekPlayback: seekPlayback,
            openURL: { openURL($0) }
        )
    }

    /// 播放失败后的重试交给视频模型；不在失败状态（例如已被重置）时重新发出当前导航意图。
    private func retryPlayback() {
        guard !videoModel.retryIfFailed() else { return }
        navigationCoordinator.retryPlayback()
    }

    private func openCommentPictures(
        _ gallery: NativePlaybackCommentPictureGallery
    ) {
        guard let bvid = navigationCoordinator.currentPlaybackBVID,
            let request = NativeCommentImagePreviewRequest(bvid: bvid, gallery: gallery)
        else { return }
        commentImagePreview.present(request)
    }

    @ViewBuilder
    private var selectedSourceRoot: some View {
        switch navigationCoordinator.selectedTab {
        case .home:
            RecommendedTabRoot(
                title: sources[.home].title,
                model: browseModel,
                gridHost: gridHost(.home),
                onSelect: navigationCoordinator.openPlayback
            )
        case .search:
            SearchTabRoot(
                title: sources[.search].title,
                session: searchSession,
                model: browseModel,
                gridHost: gridHost(.search),
                imagePipeline: imagePipeline,
                trendingSearchModel: trendingSearchModel,
                searchHistory: searchHistory,
                searchSuggestionSource: searchSuggestionSource,
                onSelect: navigationCoordinator.openPlayback
            )
        case .popular:
            PopularTabRoot(
                title: sources[.popular].title,
                model: browseModel,
                gridHost: gridHost(.popular),
                onSelect: navigationCoordinator.openPlayback
            )
        case .watchLater:
            WatchLaterTabRoot(
                title: sources[.watchLater].title,
                model: watchLaterModel,
                session: watchLaterSession,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.watchLater),
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        case .history:
            HistoryTabRoot(
                title: sources[.history].title,
                model: historyModel,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.history),
                onSelect: navigationCoordinator.openPlayback,
                onPresentAuthentication: {
                    isAuthenticationPresented = true
                }
            )
        case .favorites:
            FavoritesTabRoot(
                title: sources[.favorites].title,
                model: favoriteFolders,
                accountState: authenticationModel.accountPresentationState,
                gridHost: gridHost(.favorites),
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

/// 各来源独立的网格滚动状态；来源之间不共享可被互相覆盖的位置。
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
            relatedImageLoader: imagePipeline
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

/// 写入结果胶囊的宿主：单独成一个 View，只有它读取协调者的结果，结果变化时不让整个外壳重新求值。
private struct AccountWriteStatusOverlay: View {
    let accountWrites: AccountWriteCoordinator

    var body: some View {
        AccountWriteStatusCapsule(
            report: accountWrites.report,
            sequence: accountWrites.reportSequence
        )
    }
}
