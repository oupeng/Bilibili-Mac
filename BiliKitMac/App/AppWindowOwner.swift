import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import SwiftUI

@MainActor
/// 保存一个窗口内必须同代且跨 SwiftUI `body` 重算保持稳定的对象图。
///
/// 尤其是视频、弹幕模型与 `playerContent` 必须共享 `AppEnvironment` 中同一个
/// `AVPlayerEngine`；分别重建会造成画面、时间线与弹幕指向不同播放项目。
final class AppWindowOwner {
    let benchmarkAuthenticationOwnerID = UUID()
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let historyModel: WatchHistoryViewModel
    let uploaderSpaceModel: UploaderSpaceViewModel?
    let trendingSearchModel: TrendingSearchViewModel?
    let searchSuggestionSource: SearchSuggestionSource?
    /// 侧栏来源的描述，按侧栏顺序；与上面的模型同代构造一次。
    let sources: AppSources
    /// 本窗口全部账户复核参与者；与上面的模型同代构造一次，`AppRootView` 只读取与转交结果。
    let revalidationParticipants: AccountRevalidationParticipants
    let playerContent: AnyView
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    /// 在当前视频的播放器里跳到某秒并播放；播放器 item 不属于该视频时不动作。
    let seekPlayback: @MainActor (_ bvid: String, _ seconds: Int) -> Void
    /// 评论短链的在途解析；换视频与关窗时取消。
    let commentShortLinks = CommentShortLinkResolution()
    /// 评论图片的保存；预览关闭后已确认的保存照常完成，关窗时取消。
    let commentImageSaver = NativeCommentImageSaver()
    /// 窗口内所有封面、头像与评论图片共用的匿名有界图片管线。
    let imagePipeline: NativeVideoImagePipeline
    private let imagePipelineOwner: NativeVideoImagePipelineOwner
    private let playbackPreferencesController: PlaybackPreferencesController?
    private let systemNowPlayingCoordinator: SystemNowPlayingWindowCoordinator?
    private let watchProgressConnection: WatchProgressWindowConnection?
    private let openEnvironment: (@MainActor @Sendable () -> Void)?
    private let closeEnvironment: (@MainActor @Sendable () -> Void)?
    private let synchronizeEnvironmentSignedOutConfirmation: (@MainActor @Sendable (Bool) -> Void)?
    private var isOpen = false
    /// 关闭不可逆：之后不再打开，也不再向进程级对象登记本窗口。
    private(set) var isClosed = false

    convenience init(
        environment: AppEnvironment,
        systemNowPlayingController: SystemNowPlayingController? = nil
    ) {
        let browseModel = environment.makeBrowseViewModel()
        let videoModel = environment.makeVideoViewModel()
        let commentsModel = environment.makeCommentsViewModel()
        let danmakuModel = environment.makeDanmakuViewModel()
        let uploaderSpaceModel = environment.makeUploaderSpaceViewModel()
        let watchProgressConnection = environment.makeWatchProgressConnection(
            videoModel: videoModel
        )
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { videoModel.select($0) },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            closeSidebarContext: {
                uploaderSpaceModel.close()
            }
        )
        self.init(
            navigationCoordinator: navigationCoordinator,
            browseModel: browseModel,
            videoModel: videoModel,
            commentsModel: commentsModel,
            danmakuModel: danmakuModel,
            authenticationModel: environment.makeAuthenticationViewModel(),
            historyModel: environment.makeWatchHistoryViewModel(),
            uploaderSpaceModel: uploaderSpaceModel,
            trendingSearchModel: environment.makeTrendingSearchViewModel(),
            searchSuggestionSource: environment.makeSearchSuggestionSource(),
            playerContent: environment.makePlayerView(
                videoModel: videoModel,
                danmakuModel: danmakuModel
            ),
            commentAssetURLResolver: environment.commentAssetURLResolver,
            commentLinkRouter: environment.commentLinkRouter,
            seekPlayback: environment.seekPlayback(bvid:toSeconds:),
            playbackPreferencesController: environment.playbackPreferencesController,
            systemNowPlayingController: systemNowPlayingController,
            systemNowPlayingConnection:
                environment.makeSystemNowPlayingPlaybackConnection(),
            watchProgressConnection: watchProgressConnection,
            openEnvironment: environment.open,
            closeEnvironment: environment.close,
            synchronizeEnvironmentSignedOutConfirmation:
                environment.synchronizeSignedOutConfirmation
        )
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: BrowseViewModel,
        videoModel: VideoViewModel,
        commentsModel: PlaybackCommentsViewModel? = nil,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        uploaderSpaceModel: UploaderSpaceViewModel? = nil,
        trendingSearchModel: TrendingSearchViewModel? = nil,
        searchSuggestionSource: SearchSuggestionSource? = nil,
        playerContent: AnyView,
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _, _ in nil },
        commentLinkRouter: @escaping CommentLinkRouter = { _ in nil },
        seekPlayback: @escaping @MainActor (String, Int) -> Void = { _, _ in },
        imagePipelineOwner: NativeVideoImagePipelineOwner =
            NativeVideoImagePipelineOwner(cacheLimits: .window),
        playbackPreferencesController: PlaybackPreferencesController? = nil,
        systemNowPlayingController: SystemNowPlayingController? = nil,
        systemNowPlayingConnection: SystemNowPlayingPlaybackConnection? = nil,
        watchProgressConnection: WatchProgressWindowConnection? = nil,
        openEnvironment: (@MainActor @Sendable () -> Void)? = nil,
        closeEnvironment: (@MainActor @Sendable () -> Void)? = nil,
        synchronizeEnvironmentSignedOutConfirmation:
            (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        self.navigationCoordinator = navigationCoordinator
        self.browseModel = browseModel
        self.videoModel = videoModel
        self.commentsModel = commentsModel
        self.danmakuModel = danmakuModel
        self.authenticationModel = authenticationModel
        self.historyModel = historyModel
        self.uploaderSpaceModel = uploaderSpaceModel
        self.trendingSearchModel = trendingSearchModel
        self.searchSuggestionSource = searchSuggestionSource
        sources = AppSources(
            browseModel: browseModel,
            historyModel: historyModel,
            trendingSearchModel: trendingSearchModel
        )
        let windowWide: [(any AccountRevalidationParticipant)?] = [
            videoModel, browseModel, danmakuModel, commentsModel, uploaderSpaceModel
        ]
        revalidationParticipants = AccountRevalidationParticipants(
            entries: windowWide.compactMap { $0 }.map { .init(participant: $0, route: nil) }
                + sources.ordered.compactMap { source in
                    source.revalidationParticipant.map { .init(participant: $0, route: source.id) }
                }
        )
        self.playerContent = playerContent
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentLinkRouter = commentLinkRouter
        self.seekPlayback = seekPlayback
        self.imagePipelineOwner = imagePipelineOwner
        imagePipeline = imagePipelineOwner.pipeline
        self.playbackPreferencesController = playbackPreferencesController
        if let systemNowPlayingController, let systemNowPlayingConnection {
            systemNowPlayingCoordinator = SystemNowPlayingWindowCoordinator(
                controller: systemNowPlayingController,
                connection: systemNowPlayingConnection,
                videoModel: videoModel
            )
        } else {
            systemNowPlayingCoordinator = nil
        }
        self.watchProgressConnection = watchProgressConnection
        self.openEnvironment = openEnvironment
        self.closeEnvironment = closeEnvironment
        self.synchronizeEnvironmentSignedOutConfirmation =
            synchronizeEnvironmentSignedOutConfirmation
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        openEnvironment?()
        watchProgressConnection?.start()
        systemNowPlayingCoordinator?.start()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        commentShortLinks.cancel()
        commentImageSaver.cancel()
        watchProgressConnection?.stop()
        systemNowPlayingCoordinator?.close()
        imagePipelineOwner.shutdown()
        if isOpen {
            closeEnvironment?()
        }
    }

    func markWindowActive() {
        systemNowPlayingCoordinator?.markWindowActive()
    }

    /// 主 API 的「已确认未登录」；由 `AccountSignedOutConfirmation.isConfirmed` 判定后传入。
    func synchronizeSignedOutConfirmation(_ isConfirmed: Bool) {
        synchronizeEnvironmentSignedOutConfirmation?(isConfirmed)
    }

    func synchronizeWatchProgressAccess(_ scope: AccountSessionScope) {
        let isSignedIn: Bool
        if case .signedIn = scope {
            isSignedIn = true
        } else {
            isSignedIn = false
        }
        watchProgressConnection?.setReportingAccess(isSignedIn)
    }
}
