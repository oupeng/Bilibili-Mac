import Foundation
import Testing

@testable import BiliApplication

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackTimelineStoreTests {
    @Test
    func virtualTimelineTracksPauseRateAndSeekGeneration() {
        let store = PlaybackTimelineStore()
        let identity = PlaybackItemIdentity(
            bvid: "BV1TimelineFixture",
            cid: 900_001
        )

        let token = store.beginItem(identity: identity)
        let loadGeneration = store.currentSnapshot.discontinuityGeneration
        store.markReady(token: token, durationSeconds: 120)
        store.update(
            token: token,
            positionSeconds: 12.5,
            rate: 2,
            state: .playing
        )

        #expect(store.currentSnapshot.identity == identity)
        #expect(store.currentSnapshot.positionSeconds == 12.5)
        #expect(store.currentSnapshot.durationSeconds == 120)
        #expect(store.currentSnapshot.rate == 2)
        #expect(store.currentSnapshot.state == .playing)

        store.update(token: token, rate: 0, state: .paused)
        #expect(store.currentSnapshot.positionSeconds == 12.5)
        #expect(store.currentSnapshot.rate == 0)
        #expect(store.currentSnapshot.state == .paused)

        store.markDiscontinuity(token: token, positionSeconds: 45)
        #expect(store.currentSnapshot.positionSeconds == 45)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == loadGeneration + 1
        )

        store.markDiscontinuity(token: token, positionSeconds: 8)
        #expect(store.currentSnapshot.positionSeconds == 8)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == loadGeneration + 2
        )
    }

    @Test
    func readyTransitionDoesNotOverwriteAnExistingUserState() {
        let store = PlaybackTimelineStore()
        let identity = PlaybackItemIdentity(
            bvid: "BV1UserIntentFixture",
            cid: 900_001
        )
        let token = store.beginItem(identity: identity)

        store.update(
            token: token,
            positionSeconds: 3,
            rate: 0,
            state: .paused
        )
        store.markReady(token: token, durationSeconds: 120)

        #expect(store.currentSnapshot.positionSeconds == 3)
        #expect(store.currentSnapshot.durationSeconds == 120)
        #expect(store.currentSnapshot.rate == 0)
        #expect(store.currentSnapshot.state == .paused)
    }

    @Test
    func seekOrReplayClearsEndedStateOnTheSameItem() {
        let store = PlaybackTimelineStore()
        let token = store.beginItem(
            identity: PlaybackItemIdentity(
                bvid: "BV1EndedTimeline",
                cid: 900_001
            )
        )
        store.markReady(token: token, durationSeconds: 120)
        store.update(
            token: token,
            positionSeconds: 120,
            rate: 0,
            state: .ended
        )

        store.markDiscontinuity(token: token, positionSeconds: 20)

        #expect(store.currentSnapshot.state == .paused)
        #expect(store.currentSnapshot.positionSeconds == 20)
    }

    @Test
    func replacementRejectsOldItemUpdatesAndClear() {
        let store = PlaybackTimelineStore()
        let oldIdentity = PlaybackItemIdentity(
            bvid: "BV1OldTimeline",
            cid: 900_001
        )
        let newIdentity = PlaybackItemIdentity(
            bvid: "BV1NewTimeline",
            cid: 900_002
        )
        let oldToken = store.beginItem(identity: oldIdentity)
        let newToken = store.beginItem(identity: newIdentity)
        let replacementGeneration = store.currentSnapshot.discontinuityGeneration

        store.update(
            token: oldToken,
            positionSeconds: 99,
            rate: 1,
            state: .playing
        )
        store.clear(token: oldToken)

        #expect(store.currentSnapshot.identity == newIdentity)
        #expect(store.currentSnapshot.positionSeconds == 0)
        #expect(store.currentSnapshot.state == .loading)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == replacementGeneration
        )

        store.clear(token: newToken)
        #expect(store.currentSnapshot.identity == nil)
        #expect(store.currentSnapshot.state == .idle)
        #expect(
            store.currentSnapshot.discontinuityGeneration
                == replacementGeneration + 1
        )
    }

    /// 落地代号只在换项、落地、续播起点与 clear 时前进；seeking 与普通不连续都不推进它。
    @Test
    func landingGenerationAdvancesOnlyOnLandings() {
        let store = PlaybackTimelineStore()
        let token = store.beginItem(
            identity: PlaybackItemIdentity(bvid: "BV1LandingTimeline", cid: 900_001)
        )
        let begun = store.currentSnapshot.landingGeneration
        store.markReady(token: token, durationSeconds: 120)
        store.update(token: token, positionSeconds: 5, rate: 1, state: .playing)

        store.beginSeeking(token: token, positionSeconds: 40)
        #expect(store.currentSnapshot.seekPhase == .seeking)
        #expect(store.currentSnapshot.positionSeconds == 40)
        store.markDiscontinuity(token: token, positionSeconds: 40)
        #expect(store.currentSnapshot.seekPhase == .seeking)
        #expect(store.currentSnapshot.landingGeneration == begun)

        store.land(token: token, positionSeconds: 40.5)
        #expect(store.currentSnapshot.seekPhase == .settled)
        #expect(store.currentSnapshot.positionSeconds == 40.5)
        #expect(store.currentSnapshot.landingGeneration == begun + 1)

        store.markDiscontinuity(token: token, positionSeconds: 60, lands: true)
        #expect(store.currentSnapshot.landingGeneration == begun + 2)

        store.clear(token: token)
        #expect(store.currentSnapshot.landingGeneration == begun + 3)
        #expect(store.currentSnapshot.seekPhase == .settled)
    }

    @Test
    func newSubscriberReceivesCurrentSnapshot() async {
        let store = PlaybackTimelineStore()
        let identity = PlaybackItemIdentity(
            bvid: "BV1CurrentTimeline",
            cid: 900_001
        )
        _ = store.beginItem(identity: identity)

        let stream = store.updates()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        #expect(first == store.currentSnapshot)
    }

    @Test
    func snapshotNormalizesInvalidNumericInputAndRedactsIdentity() {
        let identity = PlaybackItemIdentity(
            bvid: "BV1PrivateFixture",
            cid: 900_001
        )
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: -Double.infinity,
            durationSeconds: Double.nan,
            rate: -Double.infinity,
            state: .playing,
            discontinuityGeneration: 1
        )

        #expect(snapshot.positionSeconds == 0)
        #expect(snapshot.durationSeconds == nil)
        #expect(snapshot.rate == 0)
        #expect(!String(describing: identity).contains(identity.bvid))
        #expect(!String(reflecting: identity).contains(String(identity.cid)))
    }
}
