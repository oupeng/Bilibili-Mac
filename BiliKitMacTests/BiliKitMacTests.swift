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
            owner = AppWindowOwner(environment: environment)
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
            environment: AppEnvironment.live(accountSessionCoordinator: AccountSessionCoordinator())
        )
        #expect(!owner.isClosed)

        owner.close()
        owner.open()

        #expect(owner.isClosed)
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
