import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Foundation
import Testing

@testable import BiliKit

/// 评论链接的执行：视频在应用内播放或原地跳转，时间戳只在有播放时跳转，空间链接在侧栏打开（没有空间功能时打开
/// 网页），网页与解析不出的短链交给浏览器。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentLinkOpenerTests {
    private let fixture = VideoFixture()
    private let webURL = URL(string: "https://example.invalid/article")!
    private let shortURL = URL(string: "https://example.invalid/short")!

    @Test
    func videoLinksOpenPlaybackUnlessTheyCanSeekInPlace() async {
        let harness = OpenerHarness(fixture: fixture, uploaderSpace: nil)
        let linkIntent = PlaybackSelectionIntent(bvid: fixture.bvid, preferredStartSeconds: 30)

        harness.opener.open(.playback(linkIntent))
        await waitUntilSettled(harness.videoModel)
        #expect(harness.recorder.startedIntents == [linkIntent])
        #expect(harness.coordinator.currentPlaybackBVID == fixture.bvid)

        harness.opener.open(.playback(linkIntent))
        #expect(harness.recorder.seeks == ["\(fixture.bvid)@30"])
        #expect(harness.recorder.startedIntents == [linkIntent])

        let otherIntent = PlaybackSelectionIntent(bvid: "BV1OtherVideo", preferredStartSeconds: 30)
        harness.opener.open(.playback(otherIntent))
        #expect(harness.recorder.startedIntents == [linkIntent, otherIntent])
        #expect(harness.recorder.seeks.count == 1)
    }

    @Test
    func timestampsSeekOnlyWhilePlaying() async {
        let harness = OpenerHarness(fixture: fixture, uploaderSpace: nil)

        harness.opener.open(.seek(seconds: 10))
        #expect(harness.recorder.seeks.isEmpty)

        harness.coordinator.openPlayback(fixture.bvid)
        await waitUntilSettled(harness.videoModel)
        harness.opener.open(.seek(seconds: 10))
        #expect(harness.recorder.seeks == ["\(fixture.bvid)@10"])
    }

    @Test
    func spaceLinksOpenTheSidebarSpaceOrFallBackToTheWeb() async throws {
        let profiles = PendingUploaderProfileRepository()
        let withSpace = OpenerHarness(
            fixture: fixture,
            uploaderSpace: makeUploaderSpace(profiles: profiles)
        )
        let withoutSpace = OpenerHarness(fixture: fixture, uploaderSpace: nil)

        withSpace.opener.open(.space(memberID: 42, webFallback: webURL))
        withoutSpace.opener.open(.space(memberID: 42, webFallback: webURL))
        withoutSpace.opener.open(.space(memberID: 42, webFallback: nil))

        #expect(withSpace.coordinator.uploaderSpace?.owner?.id == 42)
        #expect(withSpace.recorder.openedURLs.isEmpty)
        #expect(withoutSpace.recorder.openedURLs == [webURL])
        // 只有 MID 的入口会补取名片：放行它，不留下挂起的请求。
        try await profiles.waitForRequest()
        await profiles.releaseLateResult()
    }

    @Test
    func webLinksOpenInTheBrowserAndMissingRoutesDoNothing() {
        let harness = OpenerHarness(fixture: fixture, uploaderSpace: nil)

        harness.opener.open(nil)
        harness.opener.open(.web(webURL))

        #expect(harness.recorder.openedURLs == [webURL])
        #expect(harness.recorder.startedIntents.isEmpty)
    }

    @Test
    func shortLinksOpenTheirResolvedRouteOrTheOriginalLink() async {
        let harness = OpenerHarness(fixture: fixture, uploaderSpace: nil)
        let resolvedTarget = webURL

        let resolved = await harness.recorder.nextOpenedURL {
            harness.opener.open(
                .shortLink(resolve: { .web(resolvedTarget) }, webFallback: shortURL)
            )
        }
        let unresolved = await harness.recorder.nextOpenedURL {
            harness.opener.open(.shortLink(resolve: { nil }, webFallback: shortURL))
        }

        #expect(resolved == webURL)
        #expect(unresolved == shortURL)
    }
}

/// 一个窗口里执行评论链接所需的真实导航、视频模型与短链 owner，外加记录跳转、打开网页与开始播放的替身。
@MainActor
private struct OpenerHarness {
    let recorder: OpenerRecorder
    let videoModel: VideoViewModel
    let coordinator: AppNavigationCoordinator
    let opener: CommentLinkOpener

    init(fixture: VideoFixture, uploaderSpace: UploaderSpaceViewModel?) {
        let videoModel = VideoViewModel(
            useCase: VideoUseCase(repository: FixtureVideoRepository(fixtures: [fixture])),
            playback: RecordingPlayback()
        )
        let recorder = OpenerRecorder()
        self.recorder = recorder
        coordinator = AppNavigationCoordinator(
            startPlayback: { intent in
                recorder.startedIntents.append(intent)
                videoModel.select(intent)
            },
            stopPlayback: { videoModel.reset() },
            uploaderSpace: uploaderSpace
        )
        self.videoModel = videoModel
        opener = CommentLinkOpener(
            navigationCoordinator: coordinator,
            videoModel: videoModel,
            shortLinks: CommentShortLinkResolution(),
            seekPlayback: { recorder.seeks.append("\($0)@\($1)") },
            openURL: { recorder.open($0) }
        )
    }
}

@MainActor
private final class OpenerRecorder {
    var startedIntents: [PlaybackSelectionIntent] = []
    var seeks: [String] = []
    private(set) var openedURLs: [URL] = []
    private var openWaiter: CheckedContinuation<URL, Never>?

    func open(_ url: URL) {
        openedURLs.append(url)
        openWaiter?.resume(returning: url)
        openWaiter = nil
    }

    /// 执行 `action`，等到下一次打开网页（短链在后台解析后才打开）并返回打开的地址。
    func nextOpenedURL(after action: () -> Void) async -> URL {
        await withCheckedContinuation { continuation in
            openWaiter = continuation
            action()
        }
    }
}
