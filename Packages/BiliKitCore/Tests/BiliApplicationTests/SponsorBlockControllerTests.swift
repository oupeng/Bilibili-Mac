import BiliApplication
import BiliModels
import Foundation
import Testing

private final class TestTimelineProvider: PlaybackTimelineProviding, @unchecked Sendable {
    var currentTimelineSnapshot = PlaybackTimelineSnapshot.idle
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    @MainActor
    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        AsyncStream { _ in }
    }

    @MainActor
    func observeTimeline(_ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(currentTimelineSnapshot)
        return { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    @MainActor
    func updateSnapshot(_ snapshot: PlaybackTimelineSnapshot) {
        currentTimelineSnapshot = snapshot
        for observer in observers.values {
            observer(snapshot)
        }
    }
}

private final class StubSponsorBlockRepositoryPort: SponsorBlockRepositoryPort, @unchecked Sendable {
    let segmentsToReturn: [SponsorSegment]

    init(segmentsToReturn: [SponsorSegment]) {
        self.segmentsToReturn = segmentsToReturn
    }

    func fetchSegments(bvid: String, serverURL: String) async throws -> [SponsorSegment] {
        segmentsToReturn
    }
}

struct SponsorBlockControllerTests {
    @MainActor
    @Test
    func controllerTriggersSeekWhenPositionHitsSegment() async throws {
        let segment = SponsorSegment(
            id: "seg-1",
            category: .sponsor,
            startSeconds: 10.0,
            endSeconds: 25.0,
            actionType: .skip
        )

        let repository = StubSponsorBlockRepositoryPort(segmentsToReturn: [segment])
        let timeline = TestTimelineProvider()

        var seekTarget: Double?
        let controller = SponsorBlockController(
            repository: repository,
            timeline: timeline,
            settings: .default,
            seekHandler: { target in
                seekTarget = target
            }
        )

        let identity = PlaybackItemIdentity(bvid: "BV1xx411c7m9", cid: 12345)

        // 切换视频，触发加载片段
        timeline.updateSnapshot(PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 0,
            durationSeconds: 100,
            rate: 1.0,
            state: .loading,
            discontinuityGeneration: 1
        ))

        // 给 Task 允许异步加载
        try await Task.sleep(for: .milliseconds(50))

        // 推进时间到 10.5 秒 (处于片段内)
        timeline.updateSnapshot(PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: 10.5,
            durationSeconds: 100,
            rate: 1.0,
            state: .playing,
            discontinuityGeneration: 2
        ))

        #expect(seekTarget == 25.0)
    }
}
