import AVFoundation
import BiliAPI
import BiliApplication
import BiliAuth
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import BiliNetworking
import BiliPlayback
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import SwiftUI

/// App 的 Composition Root：创建具体 adapter，并把它们收窄为 Feature 所需的 port。
///
/// 这里刻意同时看见 API、认证、播放和弹幕实现。一个环境只创建一个 `AVPlayerEngine`，
/// 原生字幕、弹幕、视频模型与 AppKit player host 必须共享它的播放 identity 和时间线。
/// 弹幕 renderer 的系统内存压力监听也由环境持有，`close` 时先取消。
@MainActor
struct AppEnvironment {
    private let playerEngine: AVPlayerEngine
    /// 字幕目录发现的凭据失效；只转给本环境最新创建的视频模型。
    private let subtitleAuthenticationInvalidations: SubtitleAuthenticationInvalidationRelay
    let playbackPreferencesController: PlaybackPreferencesController
    private let feedRepository: any FeedRepository
    private let videoRepository: any VideoRepository
    private let relatedVideoRepository: any RelatedVideoRepository
    private let trendingSearchRepository: any TrendingSearchRepository
    private let searchSuggestionRepository: any SearchSuggestionRepository
    private let uploaderProfileRepository: any UploaderProfileRepository
    private let uploaderVideoRepository: any UploaderVideoRepository
    private let commentRepository: any CommentRepository
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentLinkRouter: CommentLinkRouter
    private let historyRepository: any WatchHistoryRepository
    private let watchProgressRepository: any WatchProgressRepository
    private let danmakuSession: DanmakuSession
    private let danmakuController: DanmakuPresentationController
    private let danmakuRenderer: CoreAnimationDanmakuRenderer
    private let danmakuMemoryPressure: SystemMemoryPressureObserver
    private let danmakuPreferencesStore: any DanmakuPreferencesStoring
    private let authenticationService: any AuthenticationServicing
    private let authenticationQRCodeProvider: any AuthenticationQRCodeProviding
    let open: @MainActor @Sendable () -> Void
    let close: @MainActor @Sendable () -> Void
    let synchronizeSignedOutConfirmation: @MainActor @Sendable (Bool) -> Void

    init(
        feedRepository: any FeedRepository,
        videoRepository: any VideoRepository,
        relatedVideoRepository: any RelatedVideoRepository,
        trendingSearchRepository: any TrendingSearchRepository,
        searchSuggestionRepository: any SearchSuggestionRepository,
        uploaderProfileRepository: any UploaderProfileRepository,
        uploaderVideoRepository: any UploaderVideoRepository,
        commentRepository: any CommentRepository,
        commentAssetURLResolver: @escaping CommentAssetURLResolver,
        commentLinkRouter: @escaping CommentLinkRouter,
        historyRepository: any WatchHistoryRepository,
        watchProgressRepository: any WatchProgressRepository,
        danmakuRepository: any DanmakuSegmentRepository,
        playerEngine: AVPlayerEngine,
        subtitleAuthenticationInvalidations: SubtitleAuthenticationInvalidationRelay,
        playbackPreferencesController: PlaybackPreferencesController,
        danmakuPreferencesStore: any DanmakuPreferencesStoring,
        authenticationService: any AuthenticationServicing,
        authenticationQRCodeProvider: any AuthenticationQRCodeProviding,
        open: @escaping @MainActor @Sendable () -> Void,
        close: @escaping @MainActor @Sendable () -> Void,
        synchronizeSignedOutConfirmation: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        self.feedRepository = feedRepository
        self.videoRepository = videoRepository
        self.relatedVideoRepository = relatedVideoRepository
        self.trendingSearchRepository = trendingSearchRepository
        self.searchSuggestionRepository = searchSuggestionRepository
        self.uploaderProfileRepository = uploaderProfileRepository
        self.uploaderVideoRepository = uploaderVideoRepository
        self.commentRepository = commentRepository
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentLinkRouter = commentLinkRouter
        self.historyRepository = historyRepository
        self.watchProgressRepository = watchProgressRepository
        self.playerEngine = playerEngine
        self.subtitleAuthenticationInvalidations = subtitleAuthenticationInvalidations
        self.playbackPreferencesController = playbackPreferencesController
        self.danmakuPreferencesStore = danmakuPreferencesStore
        let renderer = CoreAnimationDanmakuRenderer()
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        self.danmakuRenderer = renderer
        // 主队列投递，处理在 MainActor 上清空 renderer 的纹理缓存与在途准备。
        let danmakuMemoryPressure = SystemMemoryPressureObserver(queue: .main) {
            [weak renderer] in
            MainActor.assumeIsolated {
                renderer?.handleMemoryPressure()
            }
        }
        self.danmakuMemoryPressure = danmakuMemoryPressure
        self.danmakuController = controller
        self.danmakuSession = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: danmakuRepository),
            timeline: playerEngine,
            presentationSink: controller
        )
        self.authenticationService = authenticationService
        self.authenticationQRCodeProvider = authenticationQRCodeProvider
        self.open = open
        self.close = {
            danmakuMemoryPressure.cancel()
            close()
        }
        self.synchronizeSignedOutConfirmation = synchronizeSignedOutConfirmation
    }

    func makeSystemNowPlayingPlaybackConnection()
        -> SystemNowPlayingPlaybackConnection
    {
        .live(engine: playerEngine)
    }

    func makeBrowseViewModel() -> BrowseViewModel {
        BrowseViewModel(
            useCase: FeedUseCase(repository: feedRepository)
        )
    }

    func makeTrendingSearchViewModel() -> TrendingSearchViewModel {
        TrendingSearchViewModel(
            useCase: TrendingSearchUseCase(repository: trendingSearchRepository)
        )
    }

    func makeSearchSuggestionSource() -> SearchSuggestionSource {
        SearchSuggestionSource(
            useCase: SearchSuggestionUseCase(repository: searchSuggestionRepository)
        )
    }

    func makeVideoViewModel() -> VideoViewModel {
        VideoViewModel(
            useCase: VideoUseCase(repository: videoRepository),
            playback: playerEngine,
            relatedVideoUseCase: RelatedVideoUseCase(
                repository: relatedVideoRepository
            ),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: uploaderProfileRepository
            ),
            playbackAuthenticationInvalidations: subtitleAuthenticationInvalidations.makeStream()
        )
    }

    func makeUploaderSpaceViewModel() -> UploaderSpaceViewModel {
        UploaderSpaceViewModel(
            useCase: UploaderVideoUseCase(repository: uploaderVideoRepository),
            profileUseCase: UploaderProfileUseCase(repository: uploaderProfileRepository)
        )
    }

    func makeCommentsViewModel() -> PlaybackCommentsViewModel {
        PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: commentRepository)
        )
    }

    func makeDanmakuViewModel() -> DanmakuControlsViewModel {
        let preferences = danmakuPreferencesStore.load()
        return DanmakuControlsViewModel(
            presentation: danmakuSession,
            initialSpeedLevel: preferences.speedLevel,
            initialOpacity: preferences.opacity,
            initialDisplayArea: preferences.displayArea,
            initialDensity: preferences.density,
            saveSpeedLevel: { [danmakuPreferencesStore] speedLevel in
                danmakuPreferencesStore.saveSpeedLevel(speedLevel)
            },
            saveOpacity: { [danmakuPreferencesStore] opacity in
                danmakuPreferencesStore.saveOpacity(opacity)
            },
            saveDisplayArea: { [danmakuPreferencesStore] displayArea in
                danmakuPreferencesStore.saveDisplayArea(displayArea)
            },
            saveDensity: { [danmakuPreferencesStore] density in
                danmakuPreferencesStore.saveDensity(density)
            }
        )
    }

    /// 评论时间戳与链接 `t=` 的跳转：只在播放器当前 item 属于该视频时跳到该秒数并播放；超出时长、
    /// 还没有 item 或已换视频时不动作。
    func seekPlayback(bvid: String, toSeconds seconds: Int) {
        guard seconds >= 0,
            playerEngine.currentTimelineSnapshot.identity?.bvid == bvid,
            playerEngine.requestSeek(to: .seconds(seconds))
        else { return }
        playerEngine.play()
    }

    func makePlayerView(
        videoModel: VideoViewModel,
        danmakuModel: DanmakuControlsViewModel
    ) -> AnyView {
        AnyView(
            PlayerHostView(
                player: playerEngine.player,
                danmakuRenderer: danmakuRenderer,
                danmakuController: danmakuController,
                videoModel: videoModel,
                beginMomentaryPlaybackRate: { [playerEngine] rate in
                    try? playerEngine.beginMomentaryPlaybackRate(Double(rate))
                },
                endMomentaryPlaybackRate: { [playerEngine] sessionID in
                    playerEngine.endMomentaryPlaybackRate(sessionID: sessionID)
                },
                seekByTransportOffset: { [playerEngine] offset in
                    playerEngine.seekByTransportOffset(offset)
                },
                adjustVolume: { [playbackPreferencesController] offset in
                    playbackPreferencesController.adjustVolume(by: offset)
                },
                togglePlayback: { [playerEngine] in
                    playerEngine.togglePlayback()
                },
                toggleDanmaku: { [danmakuModel] in
                    danmakuModel.toggleEnabled()
                },
                toggleSubtitles: { [playerEngine] in
                    await playerEngine.toggleNativeSubtitles()
                },
                timelineUpdates: { [playerEngine] in
                    playerEngine.timelineUpdates()
                }
            )
        )
    }

    func makeAuthenticationViewModel() -> AuthenticationViewModel {
        AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: authenticationQRCodeProvider
        )
    }

    func makeWatchHistoryViewModel() -> WatchHistoryViewModel {
        WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: historyRepository)
        )
    }

    func makeWatchProgressConnection(
        videoModel: VideoViewModel
    ) -> WatchProgressWindowConnection {
        .live(repository: watchProgressRepository, timeline: playerEngine, videoModel: videoModel)
    }

    /// 创建生产对象图，并保持游客、媒体与字幕正文请求不自动继承登录 Cookie。
    ///
    /// 只有 BiliAPI 私有标记的账户读取才经过 authorizer；公开 Browse、Search、评论、
    /// playurl 与 WBI 弹幕分段在明确无本地凭据时仍请求同一个 endpoint。登出还会替换 API 的
    /// ephemeral transport，使旧认证会话中的在途请求失效。
    static func live(process: ProcessComposition) -> AppEnvironment {
        let accountSessionCoordinator = process.accountSession
        let appSettingsModel = process.settings
        let signedOutConfirmation = AccountSignedOutConfirmation()
        let api = LiveAPIClients.main(
            isConfirmedSignedOut: { signedOutConfirmation.isConfirmed }
        )
        let sessionRegistration = AppEnvironmentSessionRegistration(
            coordinator: accountSessionCoordinator,
            invalidator: api
        )
        let authenticationService = BiliAuthenticationService(
            accountReadAllowedPaths: LiveAPIClients.accountSessionValidationAllowedPaths,
            additionalSessionInvalidators: [accountSessionCoordinator]
        )
        let player = AVPlayer()
        let playbackPreferencesController = PlaybackPreferencesController(
            player: player
        )
        let subtitleRepository = BiliSubtitleRepository(client: api)
        let subtitleAuthenticationInvalidations = SubtitleAuthenticationInvalidationRelay()
        let playerEngine = AVPlayerEngine(
            player: player,
            subtitleUseCase: SubtitleUseCase(
                repository: subtitleRepository,
                reportAuthenticationInvalidation: subtitleAuthenticationInvalidations.report
            ),
            sourcePreferenceProvider: {
                appSettingsModel.playbackSourcePreference
            },
            loudnessNormalizationEnabledProvider: {
                // 与设置界面、播放侧同一门槛（macOS 27 起）；更早系统上旧偏好不生效。
                LoudnessNormalizationPolicy.isSupported
                    && appSettingsModel.loudnessNormalizationEnabled
            }
        )
        let contentRepository = BiliContentRepository(client: api)
        let commentAssetResolver = BiliCommentAssetResolver()
        let commentLinkRouting = CommentLinkRouting(
            linkResolver: BiliCommentLinkResolver(),
            shortLinkResolver: BiliShortLinkResolver()
        )
        return AppEnvironment(
            feedRepository: contentRepository,
            videoRepository: contentRepository,
            relatedVideoRepository: contentRepository,
            trendingSearchRepository: contentRepository,
            searchSuggestionRepository: contentRepository,
            uploaderProfileRepository: contentRepository,
            uploaderVideoRepository: contentRepository,
            commentRepository: BiliCommentRepository(client: api),
            commentAssetURLResolver: { reference, box in
                commentAssetResolver.imageURL(for: reference, fitting: box)
            },
            commentLinkRouter: commentLinkRouting.route(for:),
            historyRepository: BiliWatchHistoryRepository(client: api),
            watchProgressRepository: process.watchProgressRepository,
            danmakuRepository: BiliDanmakuRepository(client: api),
            playerEngine: playerEngine,
            subtitleAuthenticationInvalidations: subtitleAuthenticationInvalidations,
            playbackPreferencesController: playbackPreferencesController,
            danmakuPreferencesStore: UserDefaultsDanmakuPreferencesStore(),
            authenticationService: authenticationService,
            authenticationQRCodeProvider: AuthenticationQRCodeProvider(
                service: authenticationService
            ),
            open: { sessionRegistration.open() },
            close: {
                sessionRegistration.close()
                commentLinkRouting.shortLinkResolver.invalidate()
            },
            synchronizeSignedOutConfirmation: signedOutConfirmation.synchronize
        )
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration.production(
        surfaceWidth: 0,
        surfaceHeight: 0
    )
}

private struct AuthenticationQRCodeProvider: AuthenticationQRCodeProviding {
    let service: BiliAuthenticationService

    func makeQRCodeImage(scale: Int) async throws -> CGImage? {
        try await service.makeQRCodeImage(scale: scale)
    }
}
