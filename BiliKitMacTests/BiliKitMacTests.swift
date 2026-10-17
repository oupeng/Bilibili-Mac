import BiliApplication
import BiliModels
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct BiliKitMacTests {
    @Test
    @MainActor
    func windowOwnerRetainsPlaybackPreferencesObservation() {
        weak var weakController: PlaybackPreferencesController?
        var owner: AppWindowOwner?

        do {
            let environment = AppEnvironment.live(process: makeTestProcess())
            weakController = environment.playbackPreferencesController
            owner = AppWindowOwner(environment: environment, recordSearchHistory: { _ in })
        }

        #expect(weakController != nil)
        withExtendedLifetime(owner) {}
        owner = nil
        #expect(weakController == nil)
    }

    /// 窗口关闭不可逆：之后再 open 也保持关闭，AppRootView 据此不再向进程级测速登记本窗口。
    @Test
    @MainActor
    func windowOwnerClosureIsIrreversible() {
        let owner = AppWindowOwner(
            environment: AppEnvironment.live(process: makeTestProcess()),
            recordSearchHistory: { _ in }
        )
        #expect(!owner.isClosed)

        owner.close()
        owner.open()

        #expect(owner.isClosed)
    }

    /// 重复创建视频模型：只有最新的 stream 收到字幕凭据失效，旧 stream 结束，不会有两个消费者。
    @Test
    func subtitleInvalidationRelayFeedsOnlyTheLatestStream() async {
        let relay = SubtitleAuthenticationInvalidationRelay()
        let first = relay.makeStream()
        let second = relay.makeStream()

        relay.report()

        var firstEvents = 0
        for await _ in first { firstEvents += 1 }
        var secondIterator = second.makeAsyncIterator()
        let received: Void? = await secondIterator.next()

        #expect(firstEvents == 0)
        #expect(received != nil)
    }

    @Test
    @MainActor
    func watchProgressTargetRequiresExactPresentedIdentity() throws {
        let identity = PlaybackItemIdentity(bvid: "BV1TARGETFIXTURE", cid: 22)
        let loadIntent = PlaybackLoadIntent()

        let target = try #require(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: identity.bvid,
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            )
        )
        #expect(target.aid == 11)
        #expect(target.identity == identity)
        #expect(target.loadIntent == loadIntent)
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: "BV1REPLACEMENTFIXTURE",
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: 11,
                bvid: identity.bvid,
                cid: identity.cid + 1,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
        #expect(
            WatchProgressTargetResolution.resolve(
                aid: nil,
                bvid: identity.bvid,
                cid: identity.cid,
                identity: identity,
                loadIntent: loadIntent
            ) == nil
        )
    }

    /// 进程唯一的观看进度 writer 与它的 transport 都登记进账户会话：登出、换号与凭据失效时，transport 失效，
    /// writer 里属于旧会话的在途上报以取消结束，不算成功。
    @Test
    @MainActor
    func processWatchProgressWriterIsInvalidatedWithTheAccountSession() async throws {
        let accountSession = AccountSessionCoordinator()
        let base = WatchProgressRepositoryStub(holdsReports: true)
        let transport = RecordingSessionInvalidator()
        let writer = ProcessComposition.installWatchProgressWriter(
            base: base,
            transport: transport,
            accountSession: accountSession
        )
        let report = try makeWatchProgressReport()
        let reporting = Task { try await writer.report(report) }
        await base.waitForReportCount(1)

        await accountSession.invalidateAuthenticatedSession()
        await base.release()

        await #expect(throws: CancellationError.self) { try await reporting.value }
        #expect(await transport.invalidationCount == 1)
    }
}

private func makeWatchProgressReport() throws -> WatchProgressReport {
    let identity = PlaybackItemIdentity(bvid: "BV1WRITERFIXTURE", cid: 22)
    let target = try #require(
        WatchProgressTarget(aid: 11, identity: identity, loadIntent: PlaybackLoadIntent())
    )
    return try #require(
        WatchProgressReport(
            target: target,
            event: .ended,
            sessionStartTimestamp: 1_777_777_700,
            sessionID: "0123456789abcdef0123456789abcdef",
            generation: 1,
            sequence: 1,
            positionSeconds: 18,
            maximumPositionSeconds: 18,
            durationSeconds: 120,
            elapsedSeconds: 18,
            playedSeconds: 18,
            completed: false
        )
    )
}
