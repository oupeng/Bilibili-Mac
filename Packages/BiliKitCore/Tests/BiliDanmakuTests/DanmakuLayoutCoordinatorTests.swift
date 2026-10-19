import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定布局表 owner 的契约：设置变化后在后台整张重排、一次替换；过期设置的结果被丢弃；live resize
/// 去抖后只按最后的尺寸重排；晚到的上一段排进来后，表与从头连续排一致。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DanmakuLayoutCoordinatorTests {
    @Test
    func settingsChangeReplacesTheWholeTable() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        coordinator.setSegments([1: denseEvents(segment: 1, count: 120, seed: 1)])
        coordinator.setParameters(parameters(width: 800), debounced: false)
        try await changes.wait(until: 1)

        coordinator.setParameters(parameters(width: 1_200), debounced: false)
        try await changes.wait(until: 2)

        let placements = try #require(coordinator.layouts[1]?.placements)
        #expect(!placements.isEmpty)
        #expect(placements.allSatisfy { $0.surfaceWidthAtAdmission == 1_200 })
        // 第一张表不算重排，之后的设置变化才算。
        #expect(changes.settingsRelayouts == [false, true])
    }

    /// 已有布局表时连改两次设置：第一次的任务在途时 generation 已经变了，它的结果被丢弃，表只换成最后
    /// 一次的设置。
    @Test
    func resultsForOutdatedSettingsAreDropped() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        coordinator.setSegments([1: denseEvents(segment: 1, count: 120, seed: 2)])
        coordinator.setParameters(parameters(width: 800), debounced: false)
        try await changes.wait(until: 1)

        coordinator.setParameters(parameters(width: 960), debounced: false)
        coordinator.setParameters(parameters(width: 640), debounced: false)
        try await changes.wait(until: 2)

        #expect(coordinator.layoutParameters == parameters(width: 640))
        #expect(changes.parameters == [parameters(width: 800), parameters(width: 640)])
    }

    /// 任务进行中某段换了内容：这次的结果不收这一段，随后按新内容重排。
    @Test
    func segmentReplacedDuringAJobIsLaidOutAgain() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        let original = denseEvents(segment: 1, count: 120, seed: 6)
        let replacement = original.map {
            DanmakuEvent(
                id: "replacement-" + $0.id,
                timeSeconds: $0.timeSeconds,
                mode: $0.mode,
                text: $0.text,
                fontSize: $0.fontSize,
                colorRGB: $0.colorRGB,
                colorStyle: $0.colorStyle,
                weight: $0.weight
            )
        }
        coordinator.setParameters(parameters(width: 800), debounced: false)
        coordinator.setSegments([1: original])
        coordinator.setSegments([1: replacement])
        try await changes.wait(until: 2)

        let ids = try #require(coordinator.layouts[1]?.placements.map(\.request.event.id))
        #expect(!ids.isEmpty)
        #expect(ids.allSatisfy { $0.hasPrefix("replacement-") })
    }

    @Test
    func liveResizeRelayoutsOnceWithTheLastSize() async throws {
        let coordinator = DanmakuLayoutCoordinator()
        let changes = TableChangeRecorder(coordinator)
        coordinator.setSegments([1: denseEvents(segment: 1, count: 60, seed: 3)])
        coordinator.setParameters(parameters(width: 800), debounced: false)
        try await changes.wait(until: 1)

        for width in stride(from: 810.0, through: 900, by: 10) {
            coordinator.setParameters(parameters(width: width), debounced: true)
        }
        try await changes.wait(until: 2)

        #expect(changes.parameters == [parameters(width: 800), parameters(width: 900)])
    }

    @Test
    func lateEarlierSegmentGivesTheSameTableAsContinuousLayout() async throws {
        let first = denseEvents(segment: 1, count: 300, seed: 4)
        let second = denseEvents(segment: 2, count: 300, seed: 5)
        let late = DanmakuLayoutCoordinator()
        let lateChanges = TableChangeRecorder(late)
        late.setParameters(parameters(width: 800), debounced: false)
        late.setSegments([2: second])
        try await lateChanges.wait(until: 1)
        late.setSegments([1: first, 2: second])
        try await lateChanges.wait(until: 2)

        let continuous = DanmakuLayoutCoordinator()
        let continuousChanges = TableChangeRecorder(continuous)
        continuous.setParameters(parameters(width: 800), debounced: false)
        continuous.setSegments([1: first, 2: second])
        try await continuousChanges.wait(until: 1)

        #expect(lateChanges.settingsRelayouts == [false, false])
        #expect(late.layouts[1]?.placements == continuous.layouts[1]?.placements)
        #expect(late.layouts[2]?.placements == continuous.layouts[2]?.placements)
    }

    private func parameters(width: Double) -> DanmakuLayoutParameters {
        DanmakuLayoutParameters(
            configuration: configuration(surfaceWidth: width),
            speedLevel: .default,
            backingScale: 2,
            filter: DanmakuFilter()
        )
    }
}

/// 记录布局表的每次替换及当时的设置，可等替换次数达到某个值。
@MainActor
final class TableChangeRecorder {
    private(set) var parameters: [DanmakuLayoutParameters?] = []
    /// 每次替换是否是设置变化引起的整张重排。
    private(set) var settingsRelayouts: [Bool] = []
    private let counter = TestEventCounter()

    init(_ coordinator: DanmakuLayoutCoordinator) {
        coordinator.tableDidChange = { [weak self, weak coordinator] isSettingsRelayout in
            self?.parameters.append(coordinator?.layoutParameters)
            self?.settingsRelayouts.append(isSettingsRelayout)
            Task { await self?.counter.signal() }
        }
    }

    func wait(until count: Int) async throws {
        try await counter.wait(until: count)
    }
}
