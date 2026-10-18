import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现控制器的准入与生命周期契约：先移除过期再准入，突发与待准备队列有全局上限，
/// 暂停停表、换代清屏，过期的清屏批次与表面 owner 不能清掉当前呈现。
@MainActor
@Suite
struct DanmakuPresentationControllerTests {
    @Test
    func controllerRemovesExpiredBeforeRenderingNewAdmission() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 2)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OrderFixture", cid: 1)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "first", mode: .top)]
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 1 + DanmakuMotionPolicy.fixedSeconds + 1,
                generation: 1,
                events: [fixtureEvent(id: "second", mode: .top)]
            )
        )

        #expect(backend.lifecycle == ["+first", "-first", "+second"])
        #expect(controller.statistics.active == 1)
    }

    @Test
    func burstWorkIsBoundedBeforeTextMeasurement() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1BurstFixture", cid: 20)
        let events = (0...DanmakuLaneConfiguration.hardMaximumActiveCount).map {
            fixtureEvent(id: "event-\($0)", mode: .scrolling)
        }

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: events
            )
        )

        #expect(
            backend.measureCount
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(
            controller.statistics.droppedCapacity
                == DanmakuLaneConfiguration.hardMaximumActiveCount
        )
        #expect(backend.renderedEventIDs.count == 1)
    }

    @Test
    func pendingPreparationQueueIsGloballyBoundedAcrossBatches() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 640)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1PendingBound", cid: 1)
        let maximum = DanmakuLaneConfiguration.hardMaximumActiveCount

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: (0..<maximum).map {
                    fixtureEvent(id: "first-\($0)", mode: .scrolling)
                }
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: (0...maximum).map {
                    fixtureEvent(id: "blocked-\($0)", mode: .scrolling)
                }
            )
        )

        #expect(backend.preparationIDs.count == maximum)
        #expect(controller.statistics.droppedCapacity == maximum + 1)
        controller.clearPresentation()
        #expect(controller.statistics.active == 0)
    }

    @Test
    func pausedStateStopsClockAndGenerationChangeClearsPresentation() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1LifecycleFixture", cid: 3)

        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .paused,
                rate: 1
            )
        )
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 4,
                state: .playing,
                rate: 2
            )
        )
        #expect(backend.rates == [0, 2])
        let clearCount = backend.clearCount

        controller.apply(
            update(
                identity: identity,
                position: 8,
                generation: 5,
                events: [fixtureEvent(id: "after-seek", mode: .top)]
            )
        )
        #expect(backend.clearCount == clearCount + 1)
        #expect(controller.statistics.active == 1)

        controller.stopPresentation()
        #expect(backend.stopCount == 1)
        #expect(controller.statistics.active == 0)
    }

    @Test
    func mismatchedClearBatchCannotClearCurrentGeneration() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OldClearFixture", cid: 30)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 8,
                events: [fixtureEvent(id: "current", mode: .top)]
            )
        )
        let clearCount = backend.clearCount
        let staleClear = DanmakuBatch(
            identity: identity,
            discontinuityGeneration: 7,
            events: [],
            clearsExisting: true,
            catchesUp: false
        )

        controller.apply(
            DanmakuPresentationUpdate(
                snapshot: PlaybackTimelineSnapshot(
                    identity: identity,
                    positionSeconds: 2,
                    durationSeconds: 100,
                    rate: 1,
                    state: .playing,
                    discontinuityGeneration: 8
                ),
                batch: staleClear
            )
        )

        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)
    }

    @Test
    func surfaceResizePreservesActiveUntilOwnerReplacement() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let firstOwner = UUID()
        let replacementOwner = UUID()
        #expect(controller.attachSurface(ownerID: firstOwner))
        let identity = PlaybackItemIdentity(bvid: "BV1SurfaceFixture", cid: 31)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "before-detach", mode: .top)]
            )
        )
        #expect(controller.statistics.active == 1)
        let clearCount = backend.clearCount

        #expect(
            !controller.updateSurface(
                width: 0,
                height: 0,
                ownerID: replacementOwner
            )
        )
        #expect(
            controller.updateSurface(
                width: 0,
                height: 0,
                ownerID: firstOwner
            )
        )
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)
        #expect(
            controller.updateSurface(
                width: 800,
                height: 300,
                ownerID: firstOwner
            )
        )
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 1)

        #expect(controller.attachSurface(ownerID: replacementOwner))
        #expect(backend.clearCount == clearCount + 1)
        #expect(controller.statistics.active == 0)
        #expect(!controller.detachSurface(ownerID: firstOwner))
        #expect(backend.clearCount == clearCount + 1)

        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [fixtureEvent(id: "after-attach", mode: .top)]
            )
        )
        #expect(backend.renderedEventIDs.last == "after-attach")
        #expect(controller.statistics.active == 1)
    }
}
