import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定弹幕布局的契约：同样的事件与设置总得到同样的车道；滚动弹幕不追尾、顶部底部独占槽位；
/// 分段边界接着上一段的占用排，上一段晚到时只有本段开头会变；同屏上限按确定的规则丢弃。
@Suite
struct DanmakuLayoutPlannerTests {
    @Test
    func sameEventsAndSettingsAlwaysGiveTheSameLayout() throws {
        let events = denseEvents(segment: 1, count: 400, seed: 7)
        let first = try #require(layouts([1: events]))
        let second = try #require(layouts([1: events.reversed()]))

        #expect(first[1]?.placements == second[1]?.placements)
        #expect(first[1]?.placements.isEmpty == false)
    }

    @Test
    func scrollingNeverCatchesUpAndFixedDanmakuOwnTheirSlot() throws {
        let result = try #require(layouts([1: denseEvents(segment: 1, count: 600, seed: 3)]))
        let placements = try #require(result[1]?.placements)

        expectNoOverlap(placements, configuration: Self.configuration)
    }

    @Test
    func segmentBoundaryContinuesThePreviousSegmentsLanes() throws {
        let tail = (0..<5).map {
            scrollingEvent(id: "tail-\($0)", time: 359.5, width: 300)
        }
        let head = (0..<8).map {
            scrollingEvent(id: "head-\($0)", time: 360.2, width: 300)
        }
        let result = try #require(layouts([1: tail, 2: head]))
        let placements = (result[1]?.placements ?? []) + (result[2]?.placements ?? [])

        expectNoOverlap(placements, configuration: Self.configuration)
        // 上一段末尾的五条还占着前五条车道，本段开头从第六条车道排起。
        let headLanes = try #require(result[2]?.placements.map(\.laneIndex))
        #expect(headLanes == Array(5..<10))
    }

    @Test
    func lateEarlierSegmentOnlyChangesTheStartOfTheNextSegment() throws {
        let previous = denseEvents(segment: 1, count: 900, seed: 11)
        let current = denseEvents(segment: 2, count: 900, seed: 12)
        let alone = try #require(layouts([2: current]))
        let late = try #require(layouts([1: previous, 2: current], reusing: alone))
        let continuous = try #require(layouts([1: previous, 2: current]))

        // 晚到之后与从头连续排的结果完全一致。
        #expect(late[2]?.placements == continuous[2]?.placements)
        let before = try #require(alone[2]?.placements)
        let after = try #require(late[2]?.placements)
        expectNoOverlap((late[1]?.placements ?? []) + after, configuration: Self.configuration)

        // 只有开头不同：两份占用收敛之后完全一致，本段后半段与晚到之前的布局相同。
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.request.event.id, $0) })
        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.request.event.id, $0) })
        let changedTimes = current.filter { beforeByID[$0.id] != afterByID[$0.id] }.map(
            \.timeSeconds
        )
        #expect(changedTimes.contains { $0 < 360 + (late[1]?.maximumDurationSeconds ?? 0) })
        #expect(changedTimes.allSatisfy { $0 < 540 })
    }

    @Test
    func reusedLayoutsStayUntilThePreviousSegmentsEndChanges() throws {
        let first = denseEvents(segment: 1, count: 300, seed: 21)
        let second = denseEvents(segment: 2, count: 300, seed: 22)
        let existing = try #require(layouts([1: first, 2: second]))
        let unchanged = try #require(layouts([1: first, 2: second], reusing: existing))

        #expect(unchanged[1]?.placements == existing[1]?.placements)
        #expect(unchanged[2]?.placements == existing[2]?.placements)
    }

    /// 相邻分段重复给出的弹幕只在前一段显示，同一段里重复的 ID 只显示一次；前一段晚到时也一样。
    @Test
    func repeatedIDsAppearOnce() throws {
        let first = [
            scrollingEvent(id: "repeated", time: 100, width: 200),
            scrollingEvent(id: "boundary", time: 359.9, width: 200)
        ]
        let second = [
            scrollingEvent(id: "repeated", time: 400, width: 200),
            scrollingEvent(id: "boundary", time: 360.1, width: 200),
            scrollingEvent(id: "twice", time: 370, width: 200),
            scrollingEvent(id: "twice", time: 380, width: 200)
        ]
        let alone = try #require(layouts([2: second]))
        let both = try #require(layouts([1: first, 2: second], reusing: alone))
        let ids = ((both[1]?.placements ?? []) + (both[2]?.placements ?? [])).map {
            "\($0.request.event.id)@\($0.admittedAtSeconds)"
        }

        #expect(ids.sorted() == ["boundary@359.9", "repeated@100.0", "twice@370.0"])
        #expect(both[2]?.placements == layouts([1: first, 2: second])?[2]?.placements)
    }

    @Test
    func capacityDropsTheSameLaterEventsEveryTime() throws {
        let capped = DanmakuLaneConfiguration(
            surfaceWidth: 800,
            surfaceHeight: 600,
            laneHeight: 30,
            minimumHorizontalGap: 12,
            maximumActiveCount: 5,
            displayAreaFraction: 1
        )
        let events = (0..<20).map {
            DanmakuEvent(
                id: String(format: "event-%02d", $0),
                timeSeconds: 10,
                mode: .top,
                text: "x",
                fontSize: 25,
                colorRGB: 0xFFFFFF,
                colorStyle: .solid,
                weight: 1
            )
        }
        let result = try #require(layouts([1: events.reversed()], configuration: capped))

        #expect(
            result[1]?.placements.map(\.request.event.id)
                == (0..<5).map { String(format: "event-%02d", $0) }
        )
    }

    @Test
    func filterAndSpeedChangeTheLayout() throws {
        let events = denseEvents(segment: 1, count: 200, seed: 5)
        let normal = try #require(layouts([1: events]))
        let fast = try #require(layouts([1: events], speedLevel: .five))
        let scrollingOnly = try #require(
            layouts([1: events], filter: DanmakuFilter(showsTop: false, showsBottom: false))
        )

        #expect(
            fast[1]?.placements.first { $0.request.event.mode == .scrolling }?.request
                .durationSeconds
                ?? 0
                < normal[1]?.placements.first { $0.request.event.mode == .scrolling }?.request
                .durationSeconds ?? 0
        )
        #expect(
            scrollingOnly[1]?.placements.allSatisfy { $0.request.event.mode == .scrolling } == true
        )
    }

    @Test
    func placementsAtATimeAreThoseOnScreenPlusTheLookahead() throws {
        let result = try #require(layouts([1: denseEvents(segment: 1, count: 500, seed: 9)]))
        let layout = try #require(result[1])

        for position in stride(from: 0.0, through: 360, by: 7.5) {
            let expected = layout.placements.filter {
                $0.admittedAtSeconds <= position + 2 && $0.expiresAtSeconds > position
            }
            let queried = layout.placements(at: position, lookahead: 2).filter {
                $0.expiresAtSeconds > position
            }
            #expect(queried == expected)
        }
    }

    static let configuration = DanmakuLaneConfiguration(
        surfaceWidth: 800,
        surfaceHeight: 300,
        laneHeight: 30,
        minimumHorizontalGap: 12,
        maximumActiveCount: DanmakuLaneConfiguration.hardMaximumActiveCount,
        displayAreaFraction: 1
    )

    private func layouts(
        _ segments: [Int: [DanmakuEvent]],
        reusing existing: [Int: DanmakuSegmentLayout] = [:],
        configuration: DanmakuLaneConfiguration = Self.configuration,
        speedLevel: DanmakuSpeedLevel = .default,
        filter: DanmakuFilter = DanmakuFilter()
    ) -> [Int: DanmakuSegmentLayout]? {
        DanmakuLayoutPlanner.layouts(
            for: segments,
            reusing: existing,
            parameters: DanmakuLayoutParameters(
                configuration: configuration,
                speedLevel: speedLevel,
                backingScale: 2,
                filter: filter
            ),
            measure: fixtureMetrics
        )
    }
}

/// 测试用的测量：宽度取文字里的数字（没有时按字数 × 20），高度固定 24，不经 Core Text。
func fixtureMetrics(_ event: DanmakuEvent) -> DanmakuTextMetrics? {
    let width = Double(event.text) ?? Double(event.text.count * 20)
    return DanmakuTextMetrics(width: width, height: 24)
}

func scrollingEvent(id: String, time: Double, width: Int) -> DanmakuEvent {
    DanmakuEvent(
        id: id,
        timeSeconds: time,
        mode: .scrolling,
        text: String(width),
        fontSize: 25,
        colorRGB: 0xFFFFFF,
        colorStyle: .solid,
        weight: 1
    )
}

/// 落在第 `segment` 段内、三种模式混合的高密度弹幕；同一 `seed` 总得到同一组。
func denseEvents(segment: Int, count: Int, seed: UInt64) -> [DanmakuEvent] {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }
    let start = Double(segment - 1) * DanmakuSegmentCache.segmentDurationSeconds
    return (0..<count).map { offset in
        let time = start + Double(next() % 3_600) / 10
        let mode: DanmakuPresentationMode =
            switch next() % 5 {
            case 0: .top
            case 1: .bottom
            default: .scrolling
            }
        return DanmakuEvent(
            id: "s\(segment)-\(offset)",
            timeSeconds: time,
            mode: mode,
            text: String(60 + Int(next() % 400)),
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
    }
}

/// 同一槽位上没有两条弹幕在同一时刻重叠：滚动弹幕前后保持最小间距直到前一条走完，顶部底部不同时占用。
func expectNoOverlap(
    _ placements: [DanmakuLanePlacement],
    configuration: DanmakuLaneConfiguration,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    func rightEdge(_ placement: DanmakuLanePlacement, at time: Double) -> Double {
        let request = placement.request
        let speed = (placement.surfaceWidthAtAdmission + request.width) / request.durationSeconds
        return placement.surfaceWidthAtAdmission + request.width
            - speed * (time - placement.admittedAtSeconds)
    }
    func leftEdge(_ placement: DanmakuLanePlacement, at time: Double) -> Double {
        rightEdge(placement, at: time) - placement.request.width
    }
    func lanes(_ placement: DanmakuLanePlacement) -> Range<Int> {
        let span = Int((placement.request.height / configuration.laneHeight).rounded(.up))
        return placement.laneIndex..<(placement.laneIndex + span)
    }
    let ordered = placements.sorted { $0.admittedAtSeconds < $1.admittedAtSeconds }
    for (offset, later) in ordered.enumerated() {
        for earlier in ordered[..<offset]
        where earlier.request.event.mode == later.request.event.mode
            && earlier.overlapDepth == later.overlapDepth
            && lanes(earlier).overlaps(lanes(later))
            && earlier.expiresAtSeconds > later.admittedAtSeconds
        {
            switch later.request.event.mode {
            case .top, .bottom:
                Issue.record(
                    "\(earlier.request.event.id) 与 \(later.request.event.id) 同时占用同一槽位",
                    sourceLocation: sourceLocation
                )
            case .scrolling:
                // 前一条走完之前，两条的间距始终不小于最小间距；匀速运动只需比较两个端点。
                let end = earlier.expiresAtSeconds
                let start = later.admittedAtSeconds
                let gapAtStart = leftEdge(later, at: start) - rightEdge(earlier, at: start)
                let gapAtEnd = leftEdge(later, at: end) - rightEdge(earlier, at: end)
                if min(gapAtStart, gapAtEnd) < configuration.minimumHorizontalGap - 1e-6 {
                    Issue.record(
                        "\(later.request.event.id) 追上了 \(earlier.request.event.id)",
                        sourceLocation: sourceLocation
                    )
                }
            }
        }
    }
}
