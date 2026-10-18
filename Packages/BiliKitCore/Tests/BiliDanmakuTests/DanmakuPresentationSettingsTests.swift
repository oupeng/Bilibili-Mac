import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定显示设置的呈现契约：显示区域、密度与速度的变化保留已在屏弹幕、只影响新准入，
/// 速度档位越快时长越短，安全边界只钳制极端输入。
@MainActor
@Suite
struct DanmakuPresentationSettingsTests {
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
}
