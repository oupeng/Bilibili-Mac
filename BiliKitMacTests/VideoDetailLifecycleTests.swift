import AppKit
import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliDanmaku
import BiliLibraryFeature
import BiliModels
import BiliVideoDetailFeature
import CoreGraphics
import SwiftUI
import Testing

@testable import BiliKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VideoDetailLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func playbackFailureStopsPresentationAndRetryStartsItAgain() async {
        let fixture = VideoFixture()
        let player = RecordingPlayback(holdsLoads: true)
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(
                repository: FixtureVideoRepository(fixtures: [fixture])
            ),
            playback: player
        )
        let presentation = RecordingPresentation()
        let danmakuModel = DanmakuControlsViewModel(presentation: presentation)
        let hostingView = NSHostingView(
            rootView: AnyView(
                VideoPlaybackView(
                    model: videoModel,
                    danmakuModel: danmakuModel,
                    onRetry: {},
                    relatedImageLoader: NoImageCardLoader()
                ) {
                    EmptyView()
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        await presentation.waitForStopCount(1)
        let baselineStopCount = presentation.stopCount

        videoModel.loadVideo(fixture.bvid)
        await player.waitForLoadCallCount(1)
        await presentation.waitForStartedCount(1)
        #expect(player.loadedIdentities.count == 1)
        #expect(presentation.startedIdentities.count == 1)
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        player.failPendingLoad()
        await waitUntilSettled(videoModel)
        await presentation.waitForStopCount(baselineStopCount + 1)
        #expect(presentation.stopCount == baselineStopCount + 1)
        guard case .failed = videoModel.state else {
            Issue.record("播放加载失败后应进入失败状态")
            return
        }
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        videoModel.loadVideo(fixture.bvid)
        await player.waitForLoadCallCount(2)
        await presentation.waitForStartedCount(2)
        #expect(player.loadedIdentities.count == 2)
        #expect(presentation.startedIdentities.count == 2)

        player.failPendingLoad()
        await waitUntilSettled(videoModel)
        await presentation.waitForStopCount(baselineStopCount + 2)
        #expect(presentation.stopCount == baselineStopCount + 2)

        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func backCancelsPendingUploaderProfileRequest()
        async throws
    {
        let fixture = VideoFixture()
        let profileRepository = PendingUploaderProfileRepository()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(
                repository: FixtureVideoRepository(fixtures: [fixture])
            ),
            playback: RecordingPlayback(),
            uploaderProfileUseCase: UploaderProfileUseCase(
                repository: profileRepository
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
            },
            uploaderSpace: nil
        )

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        try await profileRepository.waitForRequest()
        #expect(videoModel.uploaderProfileState == .loading)

        coordinator.playbackPath = []
        await profileRepository.releaseLateResult()
        try await profileRepository.waitForCompletion()

        #expect(videoModel.state == .idle)
        #expect(videoModel.presentedContext == nil)
        #expect(videoModel.uploaderProfileState == .loaded(UploaderProfile()))
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func onlyResolvedAuthenticationBoundaryClosesPlayback() async throws {
        let fixture = VideoFixture()
        let watchProgressProbe = WatchProgressConnectionProbe()
        let repository = FixtureVideoRepository(fixtures: [fixture])
        let playback = RecordingPlayback()
        let browseModel = BrowseViewModel(
            useCase: FeedUseCase(repository: EmptyFeedRepository())
        )
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: playback
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let authenticationService = LifecycleAuthenticationService(
            restoreState: .signedIn(nil),
            blocksFirstRestore: true
        )
        let authenticationModel = AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: LifecycleQRCodeProvider()
        )
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: WatchHistoryRepositoryStub()
            )
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            uploaderSpace: nil
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: browseModel,
                videoModel: videoModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: historyModel,
                playerContent: AnyView(EmptyView()),
                watchProgressConnection: watchProgressProbe.connection
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        try await authenticationService.waitForFirstRestoreStart()
        #expect(authenticationModel.sessionState == .unresolved)
        #expect(watchProgressProbe.startCount == 1)
        #expect(watchProgressProbe.accessValues == [false])

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        #expect(playback.loadedIdentities == [fixture.identity])
        #expect(videoModel.presentedContext?.detail.bvid == fixture.bvid)

        let loadCountBeforeRestore = playback.loadedIdentities.count
        let stopCountBeforeRestore = playback.stopCallCount
        await authenticationService.releaseFirstRestore()
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        #expect(playback.loadedIdentities.count == loadCountBeforeRestore)
        #expect(playback.stopCallCount == stopCountBeforeRestore)
        #expect(watchProgressProbe.accessValues.last == true)

        let identity = AccountIdentity(
            id: 42,
            displayName: "测试账号",
            avatarURL: nil
        )
        await authenticationService.setRestoreState(.signedIn(identity))
        let stopCountBeforeIdentity = playback.stopCallCount
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeIdentity + 1)
        #expect(authenticationModel.sessionState == .signedIn(identity))
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.stopCallCount == stopCountBeforeIdentity + 1)

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)

        let stopCountBeforeLogout = playback.stopCallCount
        authenticationModel.logout()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeLogout + 1)
        #expect(authenticationModel.sessionState == .signedOut)
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.stopCallCount == stopCountBeforeLogout + 1)
        #expect(watchProgressProbe.accessValues.last == false)

        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        #expect(
            playback.loadedIdentities == [
                fixture.identity,
                fixture.identity,
                fixture.identity
            ]
        )
        #expect(coordinator.currentPlaybackBVID == fixture.bvid)
        let loadCountBeforeSignIn = playback.loadedIdentities.count
        let stopCountBeforeSignIn = playback.stopCallCount

        await authenticationService.setRestoreState(.signedIn(identity))
        authenticationModel.revalidate()
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(stopCountBeforeSignIn + 1)
        #expect(authenticationModel.sessionState == .signedIn(identity))
        #expect(videoModel.state == .idle)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(playback.loadedIdentities.count == loadCountBeforeSignIn)
        #expect(playback.stopCallCount == stopCountBeforeSignIn + 1)
        #expect(watchProgressProbe.accessValues.last == true)

        window.contentView = NSView()
        #expect(watchProgressProbe.stopCount == 1)
    }

    @Test(arguments: VideoDetailCredentialFailureSource.allCases)
    @MainActor
    func invalidCredentialRevalidatesAndClosesPlayback(
        _ source: VideoDetailCredentialFailureSource
    ) async {
        let fixture = VideoFixture()
        let repository = FixtureVideoRepository(
            fixtures: [fixture],
            playbackError: source == .playback ? .authenticationInvalid : nil
        )
        let playback = RecordingPlayback()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: playback
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: LifecycleCommentRepository(
                    rootError: source == .comments ? .authenticationInvalid : nil
                )
            )
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let authenticationService = LifecycleAuthenticationService(
            restoreState: .signedIn(nil)
        )
        let authenticationModel = AuthenticationViewModel(
            service: authenticationService,
            qrCodeProvider: LifecycleQRCodeProvider()
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: {
                videoModel.loadVideo($0.bvid, preferredCID: $0.preferredCID)
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            uploaderSpace: nil
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: BrowseViewModel(
                    useCase: FeedUseCase(repository: EmptyFeedRepository())
                ),
                videoModel: videoModel,
                commentsModel: commentsModel,
                danmakuModel: danmakuModel,
                authenticationModel: authenticationModel,
                historyModel: WatchHistoryViewModel(
                    useCase: WatchHistoryUseCase(
                        repository: WatchHistoryRepositoryStub()
                    )
                ),
                playerContent: AnyView(EmptyView())
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()
        await authenticationService.waitForRestoreCallCount(1)
        await authenticationModel.waitForCurrentTask()
        #expect(authenticationModel.sessionState == .signedIn(nil))

        await authenticationService.setRestoreState(.signedOut)
        coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(videoModel)
        await authenticationService.waitForRestoreCallCount(2)
        await authenticationModel.waitForCurrentTask()
        await playback.waitForStopCallCount(1)

        #expect(authenticationModel.sessionState == .signedOut)
        #expect(coordinator.currentPlaybackBVID == nil)
        #expect(videoModel.state == .idle)
        #expect(playback.stopCallCount == 1)
        switch source {
        case .playback:
            #expect(playback.loadedIdentities.isEmpty)
        case .comments:
            #expect(commentsModel.authenticationRevalidationGeneration == 1)
        }
        window.contentView = NSView()
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func appRootActivatesCommentsByAIDAndClearsThemOnBack() async {
        let first = VideoFixture(
            aid: 700_001,
            bvid: "BV1CommentLifecycleA",
            cid: 900_001,
            title: "评论生命周期 A"
        )
        let replacement = VideoFixture(
            aid: 700_002,
            bvid: "BV1CommentLifecycleB",
            cid: 900_002,
            title: "评论生命周期 B"
        )
        let repository = FixtureVideoRepository(
            fixtures: [first, replacement]
        )
        let commentsRepository = LifecycleCommentRepository()
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: repository),
            playback: RecordingPlayback()
        )
        let commentsModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: commentsRepository)
        )
        let danmakuModel = DanmakuControlsViewModel(
            presentation: RecordingPresentation()
        )
        let coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                videoModel.loadVideo(
                    intent.bvid,
                    preferredCID: intent.preferredCID
                )
            },
            stopPlayback: {
                videoModel.reset()
                danmakuModel.reset()
            },
            uploaderSpace: nil
        )
        let hostingView = NSHostingView(
            rootView: AppRootView(
                navigationCoordinator: coordinator,
                browseModel: BrowseViewModel(
                    useCase: FeedUseCase(repository: EmptyFeedRepository())
                ),
                videoModel: videoModel,
                commentsModel: commentsModel,
                danmakuModel: danmakuModel,
                authenticationModel: AuthenticationViewModel(
                    service: LifecycleAuthenticationService(restoreState: .signedOut),
                    qrCodeProvider: LifecycleQRCodeProvider()
                ),
                historyModel: WatchHistoryViewModel(
                    useCase: WatchHistoryUseCase(
                        repository: WatchHistoryRepositoryStub()
                    )
                ),
                playerContent: AnyView(EmptyView())
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.layoutIfNeeded()

        coordinator.openPlayback(first.bvid)
        await waitUntilSettled(videoModel)
        await commentsRepository.waitForRequestCount(1)
        await commentsModel.waitForCurrentRootTask()
        #expect(commentsModel.subject == .video(aid: first.aid))
        #expect(commentsModel.rootState == .empty)

        coordinator.openPlayback(replacement.bvid)
        await waitUntilSettled(videoModel)
        await commentsRepository.waitForRequestCount(2)
        await commentsModel.waitForCurrentRootTask()
        #expect(commentsModel.subject == .video(aid: replacement.aid))
        #expect(commentsModel.rootState == .empty)
        #expect(
            await commentsRepository.requestedSubjects()
                == [.video(aid: first.aid), .video(aid: replacement.aid)]
        )

        coordinator.playbackPath = []
        await waitForObservedState {
            commentsModel.subject == nil
                && commentsModel.rootState == .idle
                && videoModel.state == .idle
        }
        #expect(commentsModel.subject == nil)
        #expect(commentsModel.rootState == .idle)
        #expect(videoModel.state == .idle)
        window.contentView = NSView()
    }
}

enum VideoDetailCredentialFailureSource: CaseIterable, Sendable {
    case playback
    case comments
}

/// 本文件唯一的评论 port 替身：记录请求的 subject；`rootError` 让根评论请求失败。
private actor LifecycleCommentRepository: CommentRepository {
    private let rootError: CommentReadError?
    private var subjects: [CommentSubjectIdentity] = []
    private var requestWaiters = CountWaiters()

    init(rootError: CommentReadError? = nil) {
        self.rootError = rootError
    }

    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage {
        subjects.append(subject)
        requestWaiters.resume(reaching: subjects.count)
        if let rootError { throw rootError }
        return CommentRootPage(
            threads: [],
            totalCount: 0,
            continuation: nil,
            isEnd: true
        )
    }

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage {
        if let rootError { throw rootError }
        return CommentReplyPage(
            rootID: rootID,
            replies: [],
            pageNumber: page,
            pageSize: pageSize,
            totalCount: 0
        )
    }

    func requestedSubjects() -> [CommentSubjectIdentity] {
        subjects
    }

    func waitForRequestCount(_ target: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: target, current: subjects.count)
        }
    }
}

@MainActor
private final class RecordingPresentation: DanmakuPresentationControlling {
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCount = 0
    private var startWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()

    func start(for identity: PlaybackItemIdentity) {
        startedIdentities.append(identity)
        startWaiters.resume(reaching: startedIdentities.count)
    }

    func setEnabled(_ enabled: Bool) {}
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}
    func setModeVisibility(scrolling: Bool, top: Bool, bottom: Bool) {}
    func setAuthenticationInvalidationHandler(_ handler: @escaping @MainActor () -> Void) {}

    func stop() {
        stopCount += 1
        stopWaiters.resume(reaching: stopCount)
    }

    func waitForStartedCount(_ target: Int) async {
        await withCheckedContinuation {
            startWaiters.add($0, until: target, current: startedIdentities.count)
        }
    }

    func waitForStopCount(_ target: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: target, current: stopCount)
        }
    }
}

private actor LifecycleAuthenticationService: AuthenticationServicing {
    private var restoreState: AuthenticationState
    private let blocksFirstRestore: Bool
    private var restoreCount = 0
    private var firstRestoreStarted = false
    private var firstRestoreReleased = false
    private var restoreStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var restoreCountWaiters = CountWaiters()

    init(
        restoreState: AuthenticationState,
        blocksFirstRestore: Bool = false
    ) {
        self.restoreState = restoreState
        self.blocksFirstRestore = blocksFirstRestore
    }

    func setRestoreState(_ state: AuthenticationState) {
        restoreState = state
    }

    func restoreCallCount() -> Int {
        restoreCount
    }

    func restore() async -> AuthenticationState {
        restoreCount += 1
        restoreCountWaiters.resume(reaching: restoreCount)
        if blocksFirstRestore, restoreCount == 1 {
            firstRestoreStarted = true
            restoreStartWaiters.resumeAll()
            await withCheckedContinuation { continuation in
                if firstRestoreReleased {
                    continuation.resume()
                } else {
                    restoreReleaseWaiters.append(continuation)
                }
            }
        }
        return restoreState
    }

    func waitForFirstRestoreStart() async throws {
        if firstRestoreStarted { return }
        await withCheckedContinuation { continuation in
            restoreStartWaiters.append(continuation)
        }
    }

    func waitForRestoreCallCount(_ target: Int) async {
        await withCheckedContinuation {
            restoreCountWaiters.add($0, until: target, current: restoreCount)
        }
    }

    func releaseFirstRestore() {
        firstRestoreReleased = true
        restoreReleaseWaiters.resumeAll()
    }

    func restoreAfterExternalSessionChange() async -> AuthenticationState { await restore() }
    func requestQRCode() async -> AuthenticationState { .signedOut }
    func pollOnce() async -> AuthenticationState { .signedOut }
    func finalizeLogin() async -> AuthenticationState { .signedOut }
    func cancelLogin() async -> AuthenticationState { .signedOut }
    func logout() async -> AuthenticationState { .signedOut }
}

@MainActor
private final class WatchProgressConnectionProbe {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var accessValues: [Bool] = []

    var connection: WatchProgressWindowConnection {
        WatchProgressWindowConnection(
            start: { [weak self] in self?.startCount += 1 },
            stop: { [weak self] in self?.stopCount += 1 },
            setReportingAccess: { [weak self] in self?.accessValues.append($0) }
        )
    }
}

private struct LifecycleQRCodeProvider: AuthenticationQRCodeProviding {
    func makeQRCodeImage(scale: Int) async throws -> CGImage? { nil }
}
