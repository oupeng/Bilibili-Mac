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
            let environment = AppEnvironment.live(
                accountSessionCoordinator: AccountSessionCoordinator()
            )
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
            environment: AppEnvironment.live(
                accountSessionCoordinator: AccountSessionCoordinator()
            ),
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

    @Test
    @MainActor
    func accountCoordinatorOwnsOneProcessWatchProgressWriter() async {
        let coordinator = AccountSessionCoordinator()
        let base = EmptyWatchProgressRepository()
        let transport = RecordingSessionInvalidator()
        var factoryCount = 0

        for _ in 0..<2 {
            _ = coordinator.resolveWatchProgressRepository {
                factoryCount += 1
                return (base, transport)
            }
        }
        #expect(factoryCount == 1)

        await coordinator.invalidateAuthenticatedSession()
        #expect(await transport.invalidationCount == 1)
    }
}

private actor EmptyWatchProgressRepository: WatchProgressRepository {
    func report(_ progress: WatchProgressReport) {}
}
