import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
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
    private let sponsorBlockConnection: SponsorBlockWindowConnection?
    private let openEnvironment: (@MainActor @Sendable () -> Void)?
    private let closeEnvironment: (@MainActor @Sendable () -> Void)?
    private var isOpen = false
    private var isClosed = false

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
        let sponsorBlockConnection = environment.makeSponsorBlockConnection()
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                AppWindowOwner.handlePlaybackSelection(
                    intent,
                    with: videoModel
                )
            },
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
            sponsorBlockConnection: sponsorBlockConnection,
            openEnvironment: environment.open,
            closeEnvironment: environment.close
        )
    }

    /// 链接带 `t=` 且指向正在播放、播放器已装好的分 P（没给分 P 视为当前分 P）、秒数在可跳转范围内时，
    /// 返回要原地跳到的秒数；其余情况交给导航打开或切换分 P。
    static func inPlaceStartSeconds(
        for intent: PlaybackSelectionIntent,
        currentPlaybackBVID: String?,
        videoModel: VideoViewModel
    ) -> Int? {
        guard let startSeconds = intent.preferredStartSeconds,
            intent.preferredCID == nil,
            intent.bvid == currentPlaybackBVID,
            intent.bvid == videoModel.presentedBVID,
            videoModel.canSeekPresentedPage(
                number: intent.preferredPageNumber,
                toSeconds: startSeconds
            )
        else { return nil }
        return startSeconds
    }

    /// 播放失败后的重试交给视频模型。
    ///
    /// 它记得链接起播时间是否已经用过，开播后才失败的重试不会跳回链接时间。不在失败状态（例如已被
    /// 重置）时重新发出当前导航意图。
    static func retryPlayback(
        coordinator: AppNavigationCoordinator,
        videoModel: VideoViewModel
    ) {
        switch videoModel.state {
        case .failed, .failedPage:
            videoModel.retry()
        case .idle, .loading, .loadingPage, .preparingPlayback, .ready:
            coordinator.retryPlayback()
        }
    }

    static func handlePlaybackSelection(
        _ intent: PlaybackSelectionIntent,
        with videoModel: VideoViewModel
    ) {
        // 只在已呈现且正在请求的就是这个视频、并且没有整体失败时就地处理。另一个视频加载中残留的
        // 旧详情不算；整体失败（详情或播放器准备失败）重新加载，重试才不会被同一身份的去重吞掉。
        var isFailed = false
        if case .failed = videoModel.state { isFailed = true }
        guard videoModel.presentedBVID == intent.bvid,
            videoModel.requestedSelectionBVID == intent.bvid,
            !isFailed
        else {
            videoModel.loadVideo(
                intent.bvid,
                preferredCID: intent.preferredCID,
                preferredPageNumber: intent.preferredPageNumber,
                startSeconds: intent.preferredStartSeconds
            )
            return
        }
        // 当前视频的分 P 序号直接换算为 CID，在现有 pages 内切换。没给分 P 或序号超出范围时
        // 已经在看这个视频，保持当前播放。
        let presentedPageCID = intent.preferredPageNumber.flatMap(
            videoModel.presentedPageCID(forNumber:)
        )
        guard let preferredCID = intent.preferredCID ?? presentedPageCID else { return }
        // 失败的分 P 收到带新起播秒数的链接时按新秒数重开，否则沿用重试。
        if videoModel.failedPageCID == preferredCID, intent.preferredStartSeconds == nil {
            videoModel.retry()
        } else {
            videoModel.selectPage(cid: preferredCID, startSeconds: intent.preferredStartSeconds)
        }
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
            NativeVideoImagePipelineOwner(),
        playbackPreferencesController: PlaybackPreferencesController? = nil,
        systemNowPlayingController: SystemNowPlayingController? = nil,
        systemNowPlayingConnection: SystemNowPlayingPlaybackConnection? = nil,
        watchProgressConnection: WatchProgressWindowConnection? = nil,
        sponsorBlockConnection: SponsorBlockWindowConnection? = nil,
        openEnvironment: (@MainActor @Sendable () -> Void)? = nil,
        closeEnvironment: (@MainActor @Sendable () -> Void)? = nil
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
        self.sponsorBlockConnection = sponsorBlockConnection
        self.openEnvironment = openEnvironment
        self.closeEnvironment = closeEnvironment
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        openEnvironment?()
        watchProgressConnection?.start()
        sponsorBlockConnection?.start()
        systemNowPlayingCoordinator?.start()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        commentShortLinks.cancel()
        commentImageSaver.cancel()
        watchProgressConnection?.stop()
        sponsorBlockConnection?.stop()
        systemNowPlayingCoordinator?.close()
        imagePipelineOwner.shutdown()
        if isOpen {
            closeEnvironment?()
        }
    }

    func markWindowActive() {
        systemNowPlayingCoordinator?.markWindowActive()
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
