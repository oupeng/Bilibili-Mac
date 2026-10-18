import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定纹理准备的呈现契约：按准备顺序上屏，identity、generation、停止或缩放变化让迟到的准备作废，
/// 同缩放的尺寸变化保留待准备项，安装失败立即归还车道。
@MainActor
@Suite
struct DanmakuPresentationPreparationTests {
    @Test
    func controllerWaitsForTextureAndPreservesPreparationOrder() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Prepared", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    fixtureEvent(id: "first", mode: .top),
                    fixtureEvent(id: "second", mode: .top)
                ]
            )
        )
        let firstID = backend.preparationIDs[0]
        let secondID = backend.preparationIDs[1]

        #expect(backend.activeEventIDs.count == 0)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(secondID)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(firstID)
        #expect(backend.renderedEventIDs == ["first", "second"])
        #expect(backend.activeEventIDs.count == 2)
    }

    @Test
    func identityReplacementRejectsLatePreparation() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let oldIdentity = PlaybackItemIdentity(bvid: "BV1OldIdentity", cid: 1)
        let newIdentity = PlaybackItemIdentity(bvid: "BV1NewIdentity", cid: 2)

        controller.apply(
            update(
                identity: oldIdentity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "old-identity", mode: .top)]
            )
        )
        let oldPreparationID = backend.preparationIDs.last!
        controller.apply(
            update(
                identity: newIdentity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "new-identity", mode: .top)]
            )
        )
        let newPreparationID = backend.preparationIDs.last!

        backend.completePreparation(oldPreparationID)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(newPreparationID)
        #expect(backend.renderedEventIDs == ["new-identity"])
        #expect(backend.activeEventIDs.count == 1)
    }

    @Test
    func generationStopAndBackingScaleInvalidateLatePreparation() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        controller.updateSurface(
            width: 800,
            height: 300,
            backingScale: 2,
            ownerID: owner
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Late", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "old-generation", mode: .top)]
            )
        )
        let oldGenerationID = backend.preparationIDs.last!
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 2
            )
        )
        backend.completePreparation(oldGenerationID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 2,
                events: [fixtureEvent(id: "old-scale", mode: .top)]
            )
        )
        let oldScaleID = backend.preparationIDs.last!
        controller.updateSurface(
            width: 800,
            height: 300,
            backingScale: 1,
            ownerID: owner
        )
        backend.completePreparation(oldScaleID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 3.5,
                generation: 2,
                events: [fixtureEvent(id: "cleared", mode: .top)]
            )
        )
        let clearedID = backend.preparationIDs.last!
        controller.clearPresentation()
        backend.completePreparation(clearedID)
        #expect(backend.renderedEventIDs.isEmpty)

        controller.apply(
            update(
                identity: identity,
                position: 4,
                generation: 2,
                events: [fixtureEvent(id: "stopped", mode: .top)]
            )
        )
        let stoppedID = backend.preparationIDs.last!
        controller.stopPresentation()
        backend.completePreparation(stoppedID)
        #expect(backend.renderedEventIDs.isEmpty)
        #expect(backend.activeEventIDs.count == 0)
        #expect(backend.cancelPreparationCount >= 3)
    }

    @Test
    func sameScaleResizeKeepsPendingPreparationAndUsesNewSurface() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 4)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        let identity = PlaybackItemIdentity(bvid: "BV1ResizePending", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "pending-resize", mode: .top)]
            )
        )
        let preparationID = backend.preparationIDs.last!
        let cancelCount = backend.cancelPreparationCount
        controller.updateSurface(
            width: 1_200,
            height: 500,
            backingScale: 2,
            ownerID: owner
        )
        #expect(backend.cancelPreparationCount == cancelCount)

        backend.completePreparation(preparationID)
        #expect(backend.renderedEventIDs == ["pending-resize"])
        #expect(
            backend.renderedPlacements.last?.surfaceWidthAtAdmission == 1_200
        )
    }

    @Test
    func failedLayerInstallImmediatelyReleasesAdmittedLane() {
        let backend = RecordingRenderingBackend()
        backend.renderPreparedResult = false
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 1)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1Install", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "failed", mode: .top)]
            )
        )
        #expect(backend.activeEventIDs.count == 0)

        backend.renderPreparedResult = true
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [fixtureEvent(id: "replacement", mode: .top)]
            )
        )
        #expect(backend.renderedEventIDs == ["replacement"])
        #expect(backend.activeEventIDs.count == 1)
    }
}
