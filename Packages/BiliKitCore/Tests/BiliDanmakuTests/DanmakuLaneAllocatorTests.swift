import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定车道准入的契约：三种模式共享显示区域、各占自己的车道；滚动弹幕不追尾，顶部底部独占槽位直到
/// 到期；高文本占连续车道；允许叠放时先用不叠放的车道再逐层叠放；同屏上限按准入顺序拒绝；显示区域按比例
/// 限制车道数；两份占用是否等价只看活动 placement 与滚动槽位的尾巴。
@Suite
struct DanmakuLaneAllocatorTests {
    @Test
    func threeModesShareDisplayRegionInAdmissionOrder() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            [
                request(id: "top", time: 1, mode: .top),
                request(id: "bottom", time: 2, mode: .bottom),
                request(id: "scroll", time: 2, mode: .scrolling)
            ],
            at: 3
        )

        #expect(
            admission.map(\.request.event.id)
                == ["top", "bottom", "scroll"]
        )
        #expect(admission.map(\.originY) == [0, 40, 0])
    }

    @Test
    func modesCanOverlapWhileSameModeStillOccupiesItsLane() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        let admission = admit(
            &allocator,
            [
                request(id: "top", mode: .top),
                request(id: "scroll", mode: .scrolling),
                request(id: "bottom", mode: .bottom),
                request(id: "top-blocked", mode: .top),
                request(id: "bottom-blocked", mode: .bottom)
            ],
            at: 0
        )

        #expect(
            admission.map(\.request.event.id)
                == ["top", "scroll", "bottom"]
        )
        #expect(admission.map(\.originY) == [0, 0, 0])
    }

    @Test
    func scrollingReusesFirstSafeLaneBeforeOpeningAnotherVerticalLane() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&allocator, [request(id: "first")], at: 0)

        let second = admit(&allocator, [request(id: "second")], at: 4)
        let third = admit(&allocator, [request(id: "third")], at: 4)

        #expect(second.map(\.laneIndex) == [0])
        #expect(third.map(\.laneIndex) == [1])
        #expect(second.map(\.overlapDepth) == [0])
        #expect(third.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingScrollingUsesSafeVerticalLaneBeforeAnotherDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceHeight: 40,
                maximumOverlapDepth: 3
            )
        )
        let initial = admit(
            &allocator,
            [
                request(id: "lane-0"),
                request(id: "lane-1"),
                request(id: "slow-overlap", duration: 20)
            ],
            at: 0
        )

        #expect(initial.map(\.laneIndex) == [0, 1, 0])
        #expect(initial.map(\.overlapDepth) == [0, 0, 1])

        let next = admit(&allocator, [request(id: "next")], at: 4)

        #expect(next.map(\.laneIndex) == [1])
        #expect(next.map(\.overlapDepth) == [0])
    }

    @Test
    func overlappingFixedDanmakuFillsEveryLaneBeforeNextDepth() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(maximumOverlapDepth: 3)
        )
        let admission = admit(
            &allocator,
            (0..<7).map {
                request(id: "top-\($0)", mode: .top)
            },
            at: 0
        )

        #expect(admission.map(\.laneIndex) == [0, 1, 2, 0, 1, 2, 0])
        #expect(admission.map(\.overlapDepth) == [0, 0, 0, 1, 1, 1, 2])
    }

    @Test
    func nonOverlappingDensityRejectsAfterAllFixedLanesAreOccupied() {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            (0..<4).map {
                request(id: "top-\($0)", mode: .top)
            },
            at: 0
        )

        #expect(admission.map(\.laneIndex) == [0, 1, 2])
        #expect(admission.map(\.overlapDepth) == [0, 0, 0])
    }

    @Test
    func scrollingLaneRejectsUnsafeEntryAndCatchUp() throws {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        let first = admit(
            &allocator,
            [request(id: "first", width: 400)],
            at: 0
        )
        #expect(first.count == 1)

        let tooEarly = admit(
            &allocator,
            [request(id: "early", width: 100)],
            at: 1
        )
        #expect(tooEarly.isEmpty)

        allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        _ = admit(
            &allocator,
            [request(id: "slow", width: 100)],
            at: 0
        )
        let catchesUp = admit(
            &allocator,
            [request(id: "fast", width: 600)],
            at: 2
        )
        #expect(catchesUp.isEmpty)

        let safe = admit(
            &allocator,
            [request(id: "safe", width: 100)],
            at: 4
        )
        #expect(safe.map(\.request.event.id) == ["safe"])
    }

    @Test
    func fixedLaneRemainsOccupiedUntilExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        _ = admit(
            &allocator,
            [request(id: "first", mode: .top, duration: 4)],
            at: 0
        )

        let occupied = admit(
            &allocator,
            [request(id: "blocked", mode: .top, duration: 4)],
            at: 3.9
        )
        #expect(occupied.isEmpty)

        let afterExpiry = admit(
            &allocator,
            [request(id: "next", mode: .top, duration: 4)],
            at: 4
        )
        #expect(afterExpiry.map(\.request.event.id) == ["next"])
    }

    @Test
    func scrollingLaneCanBeReusedImmediatelyAfterAutomaticExpiration() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(surfaceHeight: 20)
        )
        _ = admit(
            &allocator,
            [request(id: "first", duration: 2)],
            at: 0
        )

        let next = admit(
            &allocator,
            [request(id: "next", duration: 2)],
            at: 2
        )

        #expect(next.map(\.request.event.id) == ["next"])
    }

    @Test
    func capacityRejectsBeforeAdmissionAndNeverQueues() {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(maximumActiveCount: 2)
        )
        let admission = admit(
            &allocator,
            [
                request(id: "a", time: 1, mode: .top),
                request(id: "b", time: 2, mode: .scrolling),
                request(id: "c", time: 3, mode: .bottom)
            ],
            at: 3
        )

        #expect(
            admission.map(\.request.event.id) == ["a", "b"]
        )

        // 到期回收之后才有空位。
        let afterExpiry = admit(
            &allocator,
            [request(id: "d", time: 12, mode: .top)],
            at: 12
        )
        #expect(afterExpiry.map(\.request.event.id) == ["d"])
    }

    @Test
    func extremeFiniteHeightCapsLaneCountBeforeIntegerConversion() {
        let maximumActiveCount =
            DanmakuLaneConfiguration.hardMaximumActiveCount
        var allocator = DanmakuLaneAllocator(
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 1_000,
                surfaceHeight: .greatestFiniteMagnitude,
                laneHeight: 1,
                minimumHorizontalGap: 12,
                maximumActiveCount: maximumActiveCount,
                displayAreaFraction: 1
            )
        )
        let requests = (0...maximumActiveCount).map {
            request(id: "extreme-\($0)", mode: .top, height: 1)
        }

        let admission = admit(&allocator, requests, at: 0)

        #expect(admission.count == maximumActiveCount)
    }

    @Test
    func extremeFiniteRequestHeightDoesNotOverflowLaneSpanConversion() {
        var allocator = DanmakuLaneAllocator(
            configuration: DanmakuLaneConfiguration(
                surfaceWidth: 1_000,
                surfaceHeight: .greatestFiniteMagnitude,
                laneHeight: .leastNonzeroMagnitude,
                minimumHorizontalGap: 12,
                maximumActiveCount: 1,
                displayAreaFraction: 1
            )
        )

        let admission = admit(
            &allocator,
            [request(id: "extreme-span", height: .greatestFiniteMagnitude)],
            at: 0
        )

        #expect(admission.isEmpty)
    }

    @Test(arguments: [DanmakuPresentationMode.top, .scrolling])
    func tallRequestsOccupyAdjacentLanesWithoutReducingSmallTextDensity(
        mode: DanmakuPresentationMode
    ) {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            [
                request(id: "large", mode: mode, height: 39),
                request(id: "small", mode: mode, height: 18),
                request(id: "blocked-large", mode: mode, height: 39)
            ],
            at: 0
        )

        #expect(admission.map(\.request.event.id) == ["large", "small"])
        #expect(admission.map(\.laneIndex) == [0, 2])
        #expect(admission.map(\.originY) == [0, 40])
    }

    @Test(arguments: [DanmakuPresentationMode.top, .scrolling])
    func expiringTallRequestFreesEveryOccupiedLane(mode: DanmakuPresentationMode) {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(
            &allocator,
            [
                request(id: "large", mode: mode, height: 39, duration: 1),
                request(id: "small", mode: mode, height: 18, duration: 10)
            ],
            at: 0
        )
        let reused = admit(
            &allocator,
            [request(id: "large-next", mode: mode, height: 39)],
            at: 1
        )

        #expect(reused.map(\.request.event.id) == ["large-next"])
        #expect(reused.first?.laneIndex == 0)
    }

    @Test
    func tallBottomRequestUsesItsMeasuredHeightFromSurfaceEdge() throws {
        var allocator = DanmakuLaneAllocator(configuration: configuration())
        let admission = admit(
            &allocator,
            [request(id: "large-bottom", mode: .bottom, height: 39)],
            at: 0
        )

        let placement = try #require(admission.first)
        #expect(placement.laneIndex == 0)
        #expect(placement.originY == 21)
        #expect(placement.originY + placement.request.height == 60)
    }

    @Test(
        arguments: [
            (0.5, [0, 20], [60, 40]),
            (0.75, [0, 20, 40], [60, 40, 20]),
            (1, [0, 20, 40, 60], [60, 40, 20, 0])
        ] as [(Double, [Double], [Double])]
    )
    func displayAreaFractionMirrorsBottomFromSurfaceEdge(
        fraction: Double,
        expectedTop: [Double],
        expectedBottom: [Double]
    ) {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceHeight: 80,
                displayAreaFraction: fraction
            )
        )
        let top = admit(
            &allocator,
            expectedTop.indices.map { request(id: "top-\($0)", mode: .top) },
            at: 0
        )
        let bottom = admit(
            &allocator,
            expectedBottom.indices.map {
                request(id: "bottom-\($0)", mode: .bottom)
            },
            at: 0
        )

        #expect(top.map(\.originY) == expectedTop)
        #expect(bottom.map(\.originY) == expectedBottom)
    }

    @Test(arguments: DanmakuDisplayArea.allCases)
    func displayAreaLevelLimitsAvailableLaneCount(area: DanmakuDisplayArea) {
        var allocator = DanmakuLaneAllocator(
            configuration: configuration(
                surfaceHeight: 400,
                displayAreaFraction: area.fraction
            )
        )
        let admission = admit(
            &allocator,
            (0..<20).map { request(id: "\(area.rawValue)-\($0)", mode: .top) },
            at: 0
        )

        #expect(admission.count == area.rawValue / 5)
    }

    /// 两份占用等价：同样的活动 placement 与滚动尾巴；任一条到期时间不同就不等价，到期之后又等价。
    @Test
    func sameOccupancyComparesActivePlacementsAndScrollingTails() {
        var first = DanmakuLaneAllocator(configuration: configuration())
        var second = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&first, [request(id: "a"), request(id: "b", mode: .top)], at: 0)
        _ = admit(&second, [request(id: "a"), request(id: "b", mode: .top)], at: 0)
        #expect(first.hasSameOccupancy(as: second))

        var longer = DanmakuLaneAllocator(configuration: configuration())
        _ = admit(&longer, [request(id: "a", duration: 9), request(id: "b", mode: .top)], at: 0)
        #expect(!first.hasSameOccupancy(as: longer))

        _ = admit(&first, [request(id: "c", mode: .bottom)], at: 10)
        _ = admit(&longer, [request(id: "c", mode: .bottom)], at: 10)
        #expect(first.hasSameOccupancy(as: longer))
    }

    /// 逐条准入，返回被准入的 placement。
    private func admit(
        _ allocator: inout DanmakuLaneAllocator,
        _ requests: [DanmakuLaneRequest],
        at time: Double
    ) -> [DanmakuLanePlacement] {
        requests.compactMap { allocator.admit($0, at: time) }
    }

    private func configuration(
        surfaceWidth: Double = 1_000,
        surfaceHeight: Double = 60,
        maximumActiveCount: Int = 640,
        displayAreaFraction: Double = 1,
        maximumOverlapDepth: Int = 1
    ) -> DanmakuLaneConfiguration {
        DanmakuLaneConfiguration(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            laneHeight: 20,
            minimumHorizontalGap: 20,
            maximumActiveCount: maximumActiveCount,
            displayAreaFraction: displayAreaFraction,
            maximumOverlapDepth: maximumOverlapDepth
        )
    }

    private func request(
        id: String,
        time: Double = 0,
        mode: DanmakuPresentationMode = .scrolling,
        width: Double = 100,
        height: Double = 20,
        duration: Double = 8
    ) -> DanmakuLaneRequest {
        DanmakuLaneRequest(
            event: DanmakuEvent(
                id: id,
                timeSeconds: time,
                mode: mode,
                text: "fixture",
                fontSize: 24,
                colorRGB: 0xFF_FF_FF,
                colorStyle: .solid,
                weight: 5
            ),
            width: width,
            height: height,
            durationSeconds: duration
        )
    }
}
