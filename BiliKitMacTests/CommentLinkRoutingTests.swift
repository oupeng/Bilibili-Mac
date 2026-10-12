import BiliAPI
import BiliModels
import Foundation
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentLinkRoutingTests {
    private let routing = CommentLinkRouting(
        linkResolver: BiliCommentLinkResolver(),
        shortLinkResolver: BiliShortLinkResolver()
    )

    @Test
    func videoLinksBecomePlaybackIntentsWithTheirPageAndStart() {
        guard
            case .playback(let intent) = routing.route(
                for: .video(bvid: "BV1xx411c7mD", page: 2, startSeconds: 30)
            )
        else {
            Issue.record("视频链接应在应用内播放")
            return
        }
        #expect(
            intent
                == PlaybackSelectionIntent(
                    bvid: "BV1xx411c7mD",
                    preferredPageNumber: 2,
                    preferredStartSeconds: 30
                )
        )
    }

    @Test
    func spaceLinksOpenTheSpaceWithAWebFallback() {
        guard case .space(let memberID, let webFallback) = routing.route(for: .space(memberID: 42))
        else {
            Issue.record("空间链接应在空间层打开")
            return
        }
        #expect(memberID == 42)
        #expect(webFallback?.absoluteString == "https://space.bilibili.com/42")
    }

    @Test
    func timestampsSeekTheCurrentPlayback() {
        guard case .seek(let seconds) = routing.route(for: .timestamp(seconds: 83)) else {
            Issue.record("时间戳应在当前播放里跳转")
            return
        }
        #expect(seconds == 83)
    }

    /// 短链先解析再打开；没有地址的引用既不发请求也没有回退。
    @Test
    func shortLinksResolveBeforeOpening() async {
        guard
            case .shortLink(let resolve, let webFallback) = routing.route(
                for: .shortLink(CommentExternalLinkReference())
            )
        else {
            Issue.record("短链应先解析再打开")
            return
        }
        #expect(webFallback == nil)
        #expect(await resolve() == nil)
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CommentShortLinkResolutionTests {
    @Test
    func opensTheResolvedRoute() async throws {
        let url = try #require(URL(string: "https://www.bilibili.com/read/cv42"))
        let resolution = CommentShortLinkResolution()

        let opened = await withCheckedContinuation {
            (continuation: CheckedContinuation<URL?, Never>) in
            resolution.start({ .web(url) }) { route in
                continuation.resume(returning: Self.webURL(route))
            }
        }

        #expect(opened == url)
    }

    /// 新的点击取消上一个在途解析，只打开最后一次的结果。
    ///
    /// 被取消的解析在取消后仍返回路由；等它的任务结束（捕获的闭包被释放）再断言，证明靠的是取消后的
    /// 检查，而不是任务还没来得及运行。
    @Test
    func aNewClickCancelsTheResolutionInFlight() async throws {
        let first = try #require(URL(string: "https://www.bilibili.com/read/cv1"))
        let second = try #require(URL(string: "https://www.bilibili.com/read/cv2"))
        let resolution = CommentShortLinkResolution()
        let (released, release) = AsyncStream<Void>.makeStream()
        var opened: [URL?] = []

        do {
            let token = ReleaseSignal(release)
            resolution.start(
                { await Self.routeAfterCancellation(first) },
                open: { route in
                    withExtendedLifetime(token) { opened.append(Self.webURL(route)) }
                }
            )
        }
        let secondOpened = await withCheckedContinuation {
            (continuation: CheckedContinuation<URL?, Never>) in
            resolution.start({ .web(second) }) { route in
                continuation.resume(returning: Self.webURL(route))
            }
        }
        var iterator = released.makeAsyncIterator()
        await iterator.next()

        #expect(secondOpened == second)
        #expect(opened.isEmpty)
    }

    /// 换视频或关窗时取消：在途解析即使返回了路由也不再打开。
    @Test
    func cancelStopsTheResolutionInFlight() async throws {
        let url = try #require(URL(string: "https://www.bilibili.com/read/cv1"))
        let resolution = CommentShortLinkResolution()
        let (released, release) = AsyncStream<Void>.makeStream()
        var openCount = 0

        do {
            let token = ReleaseSignal(release)
            resolution.start(
                { await Self.routeAfterCancellation(url) },
                open: { _ in withExtendedLifetime(token) { openCount += 1 } }
            )
        }
        resolution.cancel()
        var iterator = released.makeAsyncIterator()
        await iterator.next()

        #expect(openCount == 0)
    }

    /// 挂起到任务被取消，再返回一个非空路由。
    private nonisolated static func routeAfterCancellation(_ url: URL) async -> CommentLinkRoute? {
        let (never, keepAlive) = AsyncStream<Void>.makeStream()
        for await _ in never {}
        keepAlive.finish()
        return .web(url)
    }

    private static func webURL(_ route: CommentLinkRoute?) -> URL? {
        guard case .web(let url) = route else { return nil }
        return url
    }
}

/// 被释放时发出信号：用来等到一个任务结束、它捕获的闭包随之释放。
private final class ReleaseSignal: Sendable {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.yield()
    }
}
