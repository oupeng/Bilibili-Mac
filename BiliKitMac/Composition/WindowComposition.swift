import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import SwiftUI

/// 窗口级组装：一个窗口必须同代、跨 SwiftUI `body` 重算保持稳定的整个对象图，由 `AppRootView` 在视图身份首次
/// 出现时构造一次（`ProcessComposition.makeWindow()`）。
///
/// 拥有本窗口的全部模型（浏览、视频、评论、弹幕、认证、稍后再看、观看历史、UP 主空间、热搜与联想、搜索会话）、导航协调、
/// 来源描述与复核参与者、播放器视图、窗口图片管线、评论短链解析与图片保存、Now Playing 与观看进度的连接，以及
/// 经 `WindowAdapters` 拿到的具体实现。只引用进程级对象（账户会话、设置、Now Playing 控制器、搜索历史），不创建
/// 也不关闭它们。视频、弹幕模型与播放器视图必须共享 adapter 里同一个播放器；分别重建会让画面、时间线与弹幕指向
/// 不同的播放项目。
///
/// 生命周期：`open()` 在窗口出现时调用一次（登记会话、开始观看进度与 Now Playing）；`close()` 在窗口消失时调用，
/// 不可逆，之后不再打开，也不再向进程级对象登记本窗口。关闭顺序见 `close()`。
@MainActor
final class WindowComposition {
    let process: ProcessComposition
    /// 本窗口在进程级测速权限汇总（`AppSettingsModel`）里的键；关窗时第一步注销。
    let benchmarkAuthenticationOwnerID = UUID()
    let navigationCoordinator: AppNavigationCoordinator
    let browseModel: BrowseViewModel
    let videoModel: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel
    let danmakuModel: DanmakuControlsViewModel
    let authenticationModel: AuthenticationViewModel
    let watchLaterModel: WatchLaterViewModel
    let historyModel: WatchHistoryViewModel
    let trendingSearchModel: TrendingSearchViewModel
    let searchSuggestionSource: SearchSuggestionSource
    /// 搜索来源的草稿、筛选与已提交的条件；关窗时由搜索来源的描述 reset。
    let searchSession: VideoSearchSession
    /// 侧栏来源的描述，按侧栏顺序。
    let sources: AppSources
    /// 本窗口全部账户复核参与者；`AppRootView` 只读取与转交结果。
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
    private let imagePipelineOwner = NativeVideoImagePipelineOwner(cacheLimits: .window)
    private let systemNowPlayingCoordinator: SystemNowPlayingWindowCoordinator
    private let watchProgressConnection: WatchProgressWindowConnection
    private let adapters: WindowAdapters
    private var isOpen = false
    /// 关闭不可逆：之后不再打开，也不再向进程级对象登记本窗口。
    private(set) var isClosed = false

    init(process: ProcessComposition, adapters: WindowAdapters) {
        self.process = process
        self.adapters = adapters
        let browseModel = BrowseViewModel(
            useCase: FeedUseCase(repository: adapters.feedRepository)
        )
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: adapters.videoRepository),
            playback: adapters.playback,
            relatedVideoUseCase: RelatedVideoUseCase(repository: adapters.relatedVideoRepository),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: adapters.uploaderProfileRepository
            ),
            playbackAuthenticationInvalidations: adapters.makePlaybackAuthenticationInvalidations()
        )
        let danmakuModel = Self.makeDanmakuModel(adapters: adapters)
        let uploaderSpace = UploaderSpaceViewModel(
            useCase: UploaderVideoUseCase(repository: adapters.uploaderVideoRepository),
            profileUseCase: UploaderProfileUseCase(repository: adapters.uploaderProfileRepository)
        )
        let navigationCoordinator = AppNavigationCoordinator(
            startPlayback: { videoModel.select($0) },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            uploaderSpace: uploaderSpace
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: adapters.commentRepository)
        )
        let watchLaterModel = WatchLaterViewModel(
            useCase: WatchLaterUseCase(repository: adapters.watchLaterRepository)
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: adapters.historyRepository)
        )
        let trendingSearchModel = TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: adapters.trendingSearchRepository)
        )
        self.navigationCoordinator = navigationCoordinator
        self.browseModel = browseModel
        self.videoModel = videoModel
        self.commentsModel = commentsModel
        self.danmakuModel = danmakuModel
        authenticationModel = AuthenticationViewModel(
            service: adapters.authenticationService,
            qrCodeProvider: adapters.authenticationQRCodeProvider
        )
        self.watchLaterModel = watchLaterModel
        self.historyModel = historyModel
        self.trendingSearchModel = trendingSearchModel
        searchSuggestionSource = SearchSuggestionSource(
            useCase: SearchSuggestionUseCase(repository: adapters.searchSuggestionRepository)
        )
        let searchSession = VideoSearchSession(
            browseModel: browseModel,
            recordHistory: process.searchHistory.record
        )
        self.searchSession = searchSession
        let sources = AppSources(
            browseModel: browseModel,
            watchLaterModel: watchLaterModel,
            historyModel: historyModel,
            searchSession: searchSession,
            trendingSearchModel: trendingSearchModel
        )
        self.sources = sources
        let windowWide: [any AccountRevalidationParticipant] = [
            videoModel, browseModel, danmakuModel, commentsModel, uploaderSpace
        ]
        revalidationParticipants = AccountRevalidationParticipants(
            entries: windowWide.map { .init(participant: $0, route: nil) }
                + sources.ordered.compactMap { source in
                    source.revalidationParticipant.map { .init(participant: $0, route: source.id) }
                }
        )
        playerContent = adapters.makePlayerContent(videoModel, danmakuModel)
        commentAssetURLResolver = adapters.commentAssetURLResolver
        commentLinkRouter = adapters.commentLinkRouter
        seekPlayback = adapters.seekPlayback
        imagePipeline = imagePipelineOwner.pipeline
        systemNowPlayingCoordinator = SystemNowPlayingWindowCoordinator(
            controller: process.nowPlaying,
            connection: adapters.nowPlayingConnection,
            videoModel: videoModel
        )
        watchProgressConnection = adapters.makeWatchProgressConnection(videoModel)
    }

    func open() {
        guard !isOpen, !isClosed else { return }
        isOpen = true
        adapters.open()
        watchProgressConnection.start()
        systemNowPlayingCoordinator.start()
    }

    /// 关窗；不可逆，重复调用不再动作。
    ///
    /// 按顺序：先从进程级测速注销本窗口；再关闭播放（停止播放器、字幕与弹幕）并恢复新窗口的来源；各来源
    /// 丢弃内容；取消认证临时任务与评论；取消短链解析与图片保存；停止观看进度与 Now Playing；关闭图片管线；最后
    /// 由 adapter 取消弹幕的内存压力监听、停止播放偏好的持久化、注销窗口 API 的会话并失效短链 session（只在打开过
    /// 之后）。模型与连接先停下自己的任务，再拆掉它们依赖的 adapter。
    func close() {
        guard !isClosed else { return }
        isClosed = true
        process.settings.removeAuthenticationOwner(benchmarkAuthenticationOwnerID)
        navigationCoordinator.resetForWindowClosure()
        sources.resetForWindowClosure()
        authenticationModel.cancelTransientWork()
        commentsModel.reset()
        commentShortLinks.cancel()
        commentImageSaver.cancel()
        watchProgressConnection.stop()
        systemNowPlayingCoordinator.close()
        imagePipelineOwner.shutdown()
        if isOpen {
            adapters.close()
        }
    }

    func markWindowActive() {
        systemNowPlayingCoordinator.markWindowActive()
    }

    /// 主 API 的「已确认未登录」；由 `AccountSignedOutConfirmation.isConfirmed` 判定后传入。
    func synchronizeSignedOutConfirmation(_ isConfirmed: Bool) {
        adapters.synchronizeSignedOutConfirmation(isConfirmed)
    }

    func synchronizeWatchProgressAccess(_ scope: AccountSessionScope) {
        let isSignedIn: Bool
        if case .signedIn = scope {
            isSignedIn = true
        } else {
            isSignedIn = false
        }
        watchProgressConnection.setReportingAccess(isSignedIn)
    }

    /// 弹幕控制模型：初值来自设备级偏好，改动立即写回。
    private static func makeDanmakuModel(adapters: WindowAdapters) -> DanmakuControlsViewModel {
        let store = adapters.danmakuPreferences
        let preferences = store.load()
        return DanmakuControlsViewModel(
            presentation: adapters.danmakuPresentation,
            initialSpeedLevel: preferences.speedLevel,
            initialOpacity: preferences.opacity,
            initialDisplayArea: preferences.displayArea,
            initialDensity: preferences.density,
            saveSpeedLevel: { store.saveSpeedLevel($0) },
            saveOpacity: { store.saveOpacity($0) },
            saveDisplayArea: { store.saveDisplayArea($0) },
            saveDensity: { store.saveDensity($0) }
        )
    }
}

extension ProcessComposition {
    /// 构造一个生产窗口：窗口自己的 adapter（API、播放器、弹幕）加上对本进程共享对象的引用。
    func makeWindow() -> WindowComposition {
        WindowComposition(process: self, adapters: .live(process: self))
    }
}
