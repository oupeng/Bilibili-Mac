import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@MainActor
@Suite
struct DanmakuPresentationControllerTests {
    @Test
    func displayAreaAndDensityChangesPreserveActiveAndAffectNewAdmissions() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1DensityFixture", cid: 1)

        controller.setDensity(.overlapping)
        controller.setDisplayArea(.half)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: (0..<11).map {
                    fixtureEvent(id: "half-\($0)", mode: .top)
                }
            )
        )

        #expect(controller.statistics.active == 5)
        #expect(controller.statistics.droppedNoLane == 6)
        #expect(backend.renderedPlacements.map(\.overlapDepth) == [0, 0, 0, 0, 0])

        let clearCount = backend.clearCount
        controller.setDisplayArea(.full)
        #expect(backend.clearCount == clearCount)
        #expect(controller.statistics.active == 5)
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: (0..<6).map {
                    fixtureEvent(id: "full-\($0)", mode: .top)
                }
            )
        )

        #expect(controller.statistics.active == 11)
        #expect(Array(backend.renderedPlacements.suffix(6)).map(\.laneIndex) == [5, 6, 7, 8, 9, 0])
        #expect(
            Array(backend.renderedPlacements.suffix(6)).map(\.overlapDepth)
                == [0, 0, 0, 0, 0, 1]
        )
    }

    @Test
    func reducingDisplayAreaChecksOldScrollingOverlapDepths() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(
                maximumActiveCount: 20,
                surfaceHeight: 60
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1AreaTransition", cid: 1)

        controller.setDensity(.overlapping)
        controller.setSpeedLevel(.five)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [
                    fixtureEvent(id: "fast-0", mode: .scrolling),
                    fixtureEvent(id: "fast-1", mode: .scrolling)
                ]
            )
        )
        controller.setSpeedLevel(.one)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "slow-overlap", mode: .scrolling)]
            )
        )

        #expect(backend.renderedPlacements.map(\.laneIndex) == [0, 1, 0])
        #expect(backend.renderedPlacements.map(\.overlapDepth) == [0, 0, 1])

        controller.setSpeedLevel(.five)
        controller.setDisplayArea(.half)
        controller.apply(
            update(
                identity: identity,
                position: 3,
                generation: 1,
                events: [fixtureEvent(id: "blocked", mode: .scrolling)]
            )
        )

        #expect(backend.renderedEventIDs == ["fast-0", "fast-1", "slow-overlap"])
        #expect(controller.statistics.droppedNoLane == 1)
    }

    @Test(
        arguments: [
            (400, 100), (1_100, 429), (3_440, 1_479)
        ] as [(Double, Double)]
    )
    func fasterSpeedLevelsMoveLongAndShortTextFaster(
        surfaceWidth: Double,
        textWidth: Double
    ) {
        let durations = DanmakuSpeedLevel.allCases.map {
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: textWidth,
                surfaceWidth: surfaceWidth,
                speedLevel: $0
            )
        }

        #expect(zip(durations, durations.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test
    func durationSafetyBoundsOnlyClampExtremeInputs() {
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 1,
                surfaceWidth: 1,
                speedLevel: .five
            ) == 1.5
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .scrolling,
                textWidth: 4_000,
                surfaceWidth: 10_000,
                speedLevel: .one
            ) == 60
        )
        #expect(
            DanmakuMotionPolicy.duration(
                for: .top,
                textWidth: 123,
                surfaceWidth: 1_100,
                speedLevel: .five
            ) == 4
        )
    }

    @Test
    func speedLevelChangeKeepsExistingPlacementAndSupportsMixedLaneSpeeds() throws {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(
                maximumActiveCount: 4,
                surfaceHeight: 30
            )
        )
        let identity = PlaybackItemIdentity(bvid: "BV1SpeedFixture", cid: 1)

        controller.setSpeedLevel(.five)
        controller.apply(
            update(
                identity: identity,
                position: 1,
                generation: 1,
                events: [fixtureEvent(id: "level-five", mode: .scrolling)]
            )
        )
        let clearCount = backend.clearCount
        controller.setSpeedLevel(.one)
        #expect(backend.clearCount == clearCount)
        controller.apply(
            update(
                identity: identity,
                position: 2,
                generation: 1,
                events: [fixtureEvent(id: "level-one", mode: .scrolling)]
            )
        )

        let first = try #require(backend.renderedPlacements.first)
        let second = try #require(backend.renderedPlacements.last)
        #expect(backend.renderedPlacements.count == 2)
        #expect(first.request.event.id == "level-five")
        #expect(second.request.event.id == "level-one")
        #expect(first.laneIndex == second.laneIndex)
        #expect(first.expiresAtSeconds > second.admittedAtSeconds)
        #expect(first.request.durationSeconds < second.request.durationSeconds)
    }

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

        #expect(controller.statistics.active == 0)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(secondID)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(firstID)
        #expect(backend.renderedEventIDs == ["first", "second"])
        #expect(controller.statistics.active == 2)
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
        #expect(controller.statistics.active == 1)
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
        #expect(controller.statistics.active == 0)
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
        #expect(controller.statistics.active == 0)
        #expect(controller.statistics.droppedCapacity == 1)

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
        #expect(controller.statistics.active == 1)
    }

    /// 补位：每条按自己的时间点准入并从已走过的位置开始；准备期间已走完的、窗口外的都不显示。
    @Test
    func catchUpBatchAdmitsAtEventTimeAndSkipsFinishedDanmaku() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CatchUpFixture", cid: 1)
        // 800pt 画面、120pt 文字的滚动弹幕约 6.8 秒走完；回看窗口约 9.8 秒；顶部弹幕 4 秒。
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "outside-window", time: 80),
                    timedEvent(id: "finished", time: 91),
                    timedEvent(id: "mid-way", time: 95),
                    timedEvent(id: "top", time: 97, mode: .top),
                    timedEvent(id: "just-entered", time: 99.5)
                ],
                catchesUp: true
            )
        )

        #expect(backend.renderedEventIDs == ["mid-way", "top", "just-entered"])
        #expect(backend.renderedPlacements.map(\.admittedAtSeconds) == [95, 97, 99.5])
        #expect(backend.renderedElapsedSeconds == [5, 3, 0.5])
        #expect(controller.statistics.droppedCapacity == 0)
    }

    /// 纹理准备乱序完成时，补位弹幕仍按时间先后准入，车道按连续播放时的位置计算。
    @Test
    func catchUpAdmissionStaysInTimeOrderWhenPreparationsFinishOutOfOrder() throws {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OrderCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "earlier", time: 96),
                    timedEvent(id: "later", time: 98)
                ],
                catchesUp: true
            )
        )
        let first = try #require(backend.preparationIDs.first)
        let second = try #require(backend.preparationIDs.last)

        backend.completePreparation(second)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(first)

        #expect(backend.renderedEventIDs == ["earlier", "later"])
        #expect(backend.renderedPlacements.map(\.admittedAtSeconds) == [96, 98])
    }

    /// 同批补位弹幕等全部纹理准备好后一起上屏，已走过的时长按上屏时刻计算，不会从左到右逐条出现。
    @Test
    func catchUpBatchAppearsTogetherOnceEveryTextureIsReady() throws {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1TogetherCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "first", time: 96),
                    timedEvent(id: "second", time: 97),
                    timedEvent(id: "third", time: 98)
                ],
                catchesUp: true
            )
        )
        #expect(backend.preparationIDs.count == 3)

        backend.completePreparation(backend.preparationIDs[0])
        backend.completePreparation(backend.preparationIDs[1])
        #expect(backend.renderedEventIDs.isEmpty)
        controller.apply(update(identity: identity, position: 100.5, generation: 1))
        backend.completePreparation(backend.preparationIDs[2])

        #expect(backend.renderedEventIDs == ["first", "second", "third"])
        #expect(backend.renderedElapsedSeconds == [4.5, 3.5, 2.5])
    }

    /// 等待一起上屏的补位弹幕被取消时归还车道，后来的弹幕仍能用同一条车道。
    @Test
    func cancelledCatchUpReleasesItsReservedLanes() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        let identity = PlaybackItemIdentity(bvid: "BV1ReleaseCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "waiting", time: 99, mode: .top),
                    timedEvent(id: "unfinished", time: 99.5, mode: .top)
                ],
                catchesUp: true
            )
        )
        backend.completePreparation(backend.preparationIDs[0])
        #expect(backend.renderedEventIDs.isEmpty)

        controller.updateSurface(width: 800, height: 300, backingScale: 3, ownerID: owner)
        backend.delaysPreparation = false
        controller.apply(
            update(
                identity: identity,
                position: 100.2,
                generation: 1,
                events: [timedEvent(id: "later", time: 100.2, mode: .top)]
            )
        )

        #expect(backend.renderedEventIDs == ["later"])
        #expect(backend.renderedPlacements.map(\.laneIndex) == [0])
        #expect(controller.statistics.active == 1)
    }

    /// 补位候选超过车道能容纳的数量时只准备最新的，其余计为容量丢弃。
    @Test
    func catchUpPreparesOnlyTheNewestCandidatesTheLanesCanHold() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20, surfaceHeight: 30)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CapCatchUp", cid: 1)
        let limit = DanmakuPresentationController.catchUpCandidatesPerLane
        let events = (0..<(limit + 2)).map {
            timedEvent(id: "candidate-\($0)", time: 99 + Double($0) * 0.1, mode: .top)
        }

        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: events,
                catchesUp: true
            )
        )

        #expect(backend.preparationIDs.count == limit)
        #expect(controller.statistics.droppedCapacity >= 2)
        #expect(!backend.renderedEventIDs.contains("candidate-0"))
        #expect(!backend.renderedEventIDs.contains("candidate-1"))
    }

    private func configuration(
        maximumActiveCount: Int,
        surfaceHeight: Double = 300
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: 800,
            surfaceHeight: surfaceHeight,
            laneHeight: 30,
            minimumHorizontalGap: 12,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: 1
        )
    }

    private func update(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing,
        rate: Double = 1,
        events: [DanmakuEvent] = [],
        catchesUp: Bool = false
    ) -> DanmakuPresentationUpdate {
        let snapshot = PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 100,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
        let batch =
            events.isEmpty
            ? nil
            : DanmakuBatch(
                identity: identity,
                discontinuityGeneration: generation,
                events: events,
                clearsExisting: false,
                catchesUp: catchesUp
            )
        return DanmakuPresentationUpdate(snapshot: snapshot, batch: batch)
    }

    private func timedEvent(
        id: String,
        time: Double,
        mode: DanmakuPresentationMode = .scrolling
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "fixture",
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
    }
}

func fixtureEvent(
    id: String,
    mode: DanmakuPresentationMode,
    colorRGB: UInt32 = 0xFFFFFF,
    fontSize: Double = 24
) -> DanmakuEvent {
    DanmakuEvent(
        id: id,
        timeSeconds: 1,
        mode: mode,
        text: "中文 日本語 한국어 Latin 😀 #",
        fontSize: fontSize,
        colorRGB: colorRGB,
        colorStyle: .solid,
        weight: 1
    )
}

@MainActor
private final class RecordingRenderingBackend: DanmakuRenderingBackend {
    weak var delegate: (any DanmakuRenderingBackendDelegate)?
    /// `+id` 表示安装、`-id` 表示移除，只用于断言移除先于新准入。
    private(set) var lifecycle: [String] = []
    private(set) var renderedEventIDs: [String] = []
    private(set) var renderedPlacements: [DanmakuLanePlacement] = []
    private(set) var renderedElapsedSeconds: [Double] = []
    private(set) var rates: [Double] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private(set) var measureCount = 0
    var delaysPreparation = false
    var renderPreparedResult = true
    private(set) var preparationIDs: [UInt64] = []
    private(set) var cancelPreparationCount = 0
    private var preparationCompletions:
        [UInt64: @MainActor @Sendable (DanmakuPreparationResult) -> Void] = [:]

    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationIDs.append(preparationID)
        if delaysPreparation {
            preparationCompletions[preparationID] = completion
        } else {
            measureCount += 1
            completion(.ready(DanmakuTextMetrics(width: 120, height: 24)))
        }
    }

    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        elapsedSeconds: Double
    ) -> Bool {
        guard renderPreparedResult else { return false }
        let eventID = placement.request.event.id
        lifecycle.append("+" + eventID)
        renderedEventIDs.append(eventID)
        renderedPlacements.append(placement)
        renderedElapsedSeconds.append(elapsedSeconds)
        return true
    }

    func completePreparation(_ preparationID: UInt64) {
        preparationCompletions[preparationID]?(
            .ready(DanmakuTextMetrics(width: 120, height: 24))
        )
    }

    func discardPreparation(preparationID: UInt64) {}

    func cancelPendingPreparations() {
        cancelPreparationCount += 1
    }

    func remove(eventID: String) {
        lifecycle.append("-" + eventID)
    }

    func clearAll() {
        clearCount += 1
    }

    func setPlaybackRate(_ rate: Double) {
        rates.append(rate)
    }

    func setOpacity(_ opacity: DanmakuOpacity) {}

    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {}

    func stop() {
        stopCount += 1
    }
}
