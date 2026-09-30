import BiliApplication
import BiliModels
import Foundation
import Testing

@MainActor
struct SponsorBlockSessionTests {
    @Test func sessionFetchesAndSkipsSegment() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1234567890", cid: 100)
        let intent = PlaybackLoadIntent()
        let store = PlaybackTimelineStore()
        let token = store.beginItem(identity: identity, loadIntent: intent)
        store.markReady(token: token, durationSeconds: 100)

        var soughtPositions: [Double] = []
        var skippedSegments: [SponsorSegment] = []

        let session = SponsorBlockSession(
            timeline: storeProvider(store),
            fetchSegments: { bvid, cid in
                [
                    SponsorSegment(
                        uuid: "seg-1",
                        cid: "100",
                        category: "sponsor",
                        startTimeSeconds: 10.0,
                        endTimeSeconds: 25.0
                    )
                ]
            },
            performSeek: { soughtPositions.append($0) },
            onSegmentSkipped: { skippedSegments.append($0) }
        )

        session.start()

        // 推进时间轴到 5.0s（尚未到达 sponsor 片段）
        store.update(token: token, positionSeconds: 5.0, state: .playing)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(soughtPositions.isEmpty)

        // 推进时间轴到 10.0s（进入 sponsor 片段区间）
        store.update(token: token, positionSeconds: 10.0, state: .playing)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(soughtPositions == [25.0])
        #expect(skippedSegments.count == 1)
        #expect(skippedSegments[0].uuid == "seg-1")

        session.stop()
    }
}

private final class StoreTimelineProvider: PlaybackTimelineProviding {
    let store: PlaybackTimelineStore

    init(store: PlaybackTimelineStore) {
        self.store = store
    }

    var currentTimelineSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        store.observe(observer)
    }
}

private func storeProvider(_ store: PlaybackTimelineStore) -> PlaybackTimelineProviding {
    StoreTimelineProvider(store: store)
}
