import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现端在任意操作序列下的契约：D 前跳、回跳、推进、读不到（换绑、解绑），与 D 无关的快照，窗口
/// resize，backing scale 变化，设置重排，分段到达与淘汰，开关弹幕，纹理部分完成或倒序完成，不论怎样交错：
/// 每一步之后屏上的 placement 都出自同一张布局表（整屏替换不拆成新旧混排），看得见的不超出那张表在 D 时刻
/// 应有的集合；停下来排空纹理之后，屏上恰是当前布局表在 D 时刻的样子，暂存不会卡住。
///
/// 操作序列由固定种子生成；步与步之间让出主线程，后台的重排在任意一步之间落地，所以每次运行的交错不同，
/// 但断言的不变量与交错无关。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuPresentationRandomOperationTests {
    private static let operationCount = 500
    /// 排空的轮数上限：一轮完成可能引出下一轮请求，后台重排也可能在中途落地，远小于这个数就该收敛。
    private static let settleRoundLimit = 10_000
    /// 第 1、2 段的末尾：大部分跳转落在这里面。
    private static let cachedEnd = 720.0
    /// D 能跳到的最远位置：超过已缓存的分段，落点可能没有弹幕。
    private static let farthestPosition = 1_150.0

    private let identity = PlaybackItemIdentity(bvid: "BV1Random", cid: 1)
    private let owner = UUID()
    private let clock = ManualDisplayClock(time: 30)
    private let backend = RecordingRenderingBackend()

    @Test
    func screenStaysConsistentUnderRandomOperations() async {
        let controller = DanmakuPresentationController(backend: backend)
        controller.attachSurface(ownerID: owner, clock: clock)
        var surface = Surface()
        update(controller, surface)
        let base = [
            1: denseEvents(segment: 1, count: 900, seed: 201),
            2: denseEvents(segment: 2, count: 900, seed: 202)
        ]
        let extra = denseEvents(segment: 3, count: 900, seed: 203)
        controller.apply(snapshot(identity: identity, position: 30, generation: 1, state: .paused))
        controller.setSegments(base, for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        backend.delaysPreparation = true

        var sequence = SeededSequence(seed: 500)
        var history = TableHistory()
        var isEnabled = true
        var hasThirdSegment = false
        var speedLevel = DanmakuSpeedLevel.default
        func wake() {
            controller.displayClockDidChange(ownerID: owner)
        }

        func restoreTime() {
            clock.time = sequence.unit() * Self.cachedEnd
            wake()
            controller.apply(snapshot(identity: identity, position: clock.time ?? 0, generation: 3))
        }

        for _ in 0..<Self.operationCount {
            // 关掉的弹幕与读不到的 D 多半在一两步之后恢复，大部分时间屏上有弹幕可以出错。
            if !isEnabled, sequence.next() % 2 == 0 {
                isEnabled = true
                controller.setEnabled(true)
            }
            if clock.time == nil, sequence.next() % 2 == 0 {
                restoreTime()
            }
            switch sequence.next() % 14 {
            case 0:
                clock.time = clock.time.map { $0 + 0.05 + sequence.unit() * 1.2 }
                wake()
            case 1:
                // 多半跳到已缓存的分段里，偶尔跳到没有弹幕的远处。
                let end = sequence.next() % 4 == 0 ? Self.farthestPosition : Self.cachedEnd
                clock.time = clock.time.map { _ in sequence.unit() * end }
                wake()
            case 2, 10, 11:
                // 小幅回跳最常见：速率 0 往回拖、在等待窗口里暂停。
                clock.time = clock.time.map { max(0, $0 - sequence.unit() * 2) }
                wake()
            case 3:
                controller.apply(
                    snapshot(
                        identity: identity,
                        position: sequence.unit() * Self.farthestPosition,
                        generation: 2
                    )
                )
            case 4:
                let windows = [(800.0, 360.0), (600.0, 300.0), (400.0, 200.0)]
                (surface.width, surface.height) = windows[Int(sequence.next() % 3)]
                update(controller, surface)
            case 5:
                // 换到 backing scale 与尺寸都不同的屏幕：已在屏的纹理要重新准备，同时整张重排，placement 全变；
                // 等新表落地，之后的几步就与这次整屏暂存交错。
                let before = placements(controller.layoutTable)
                surface.scale = surface.scale == 2 ? 3 : 2
                surface.screenWidth = surface.screenWidth == 800 ? 1_000 : 800
                surface.screenHeight = surface.screenHeight == 360 ? 450 : 360
                update(controller, surface)
                while placements(controller.layoutTable) == before {
                    await Task.yield()
                }
                // 一半的情况下紧接着速率 0 往回 seek：D 回跳撞上这次整屏暂存。
                if sequence.next() % 2 == 0 {
                    clock.time = clock.time.map { max(0, $0 - sequence.unit() * 0.5) }
                    wake()
                }
            case 6:
                // 换速度档一定改变滚动弹幕的 placement：等新表落地，之后的几步就与这次整屏暂存交错。
                let before = placements(controller.layoutTable)
                speedLevel = speedLevel == .one ? .five : .one
                controller.setSpeedLevel(speedLevel)
                while placements(controller.layoutTable) == before {
                    await Task.yield()
                }
            case 7:
                hasThirdSegment.toggle()
                controller.setSegments(
                    hasThirdSegment ? base.merging([3: extra]) { first, _ in first } : base,
                    for: identity
                )
            case 8:
                isEnabled = false
                controller.setEnabled(false)
            case 9:
                // 换绑或解绑：先清屏，D 随之读不到；之后某一步新 item 有了时间，快照随后送达。
                controller.playerItemWillChange(ownerID: owner)
                clock.time = nil
            default:
                // 逐条完成至多一半，每完成一条就检查：暂存常常跨越好几步，与回跳、重排交错；逐条上屏的
                // 新旧混排也看得见。
                let count = Int(sequence.next() % UInt64(backend.pendingPreparationCount / 2 + 1))
                for _ in 0..<count {
                    backend.completePreparations(1)
                    expectOneTable(in: controller, history: history)
                }
            }
            await Task.yield()
            history.record(controller.layoutTable)
            expectOneTable(in: controller, history: history)
        }

        controller.setEnabled(true)
        if clock.time == nil {
            restoreTime()
        }
        var rounds = 0
        while !isSettled(controller), rounds < Self.settleRoundLimit {
            backend.completePreparations(reversed: rounds % 2 == 0)
            await Task.yield()
            rounds += 1
        }
        #expect(isSettled(controller), "停止操作并排空纹理之后，屏上仍不是当前布局表在 D 时刻的样子")
    }

    /// 窗口、屏幕与 backing scale；窗口不超过屏幕，所以只改窗口的 resize 不引起重排。
    private struct Surface {
        var width = 800.0
        var height = 360.0
        var screenWidth = 800.0
        var screenHeight = 360.0
        var scale = 2.0
    }

    private func update(_ controller: DanmakuPresentationController, _ surface: Surface) {
        controller.updateSurface(
            width: surface.width,
            height: surface.height,
            screenWidth: surface.screenWidth,
            screenHeight: surface.screenHeight,
            backingScale: surface.scale,
            ownerID: owner
        )
    }

    private func placements(_ table: [Int: DanmakuSegmentLayout]) -> [Int: [DanmakuLanePlacement]] {
        table.mapValues(\.placements)
    }

    /// 序列里出现过的每张布局表，按事件 ID 索引 placement。
    private struct TableHistory {
        private(set) var tables: [[String: DanmakuLanePlacement]] = []

        mutating func record(_ table: [Int: DanmakuSegmentLayout]) {
            let byID = Dictionary(
                table.values.flatMap(\.placements).map { ($0.request.event.id, $0) }
            ) { first, _ in first }
            if tables.last != byID {
                tables.append(byID)
            }
        }
    }

    /// 屏上每个 placement 都出自同一张出现过的布局表；看得见的不超出那张表在 D 时刻应有的集合。
    private func expectOneTable(
        in controller: DanmakuPresentationController,
        history: TableHistory,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let installed = backend.installed
        let source = history.tables.last { table in
            installed.allSatisfy { table[$0.key] == $0.value }
        }
        #expect(source != nil, "屏上的 placement 混用了不同的布局表", sourceLocation: sourceLocation)
        guard let source, let position = clock.time else { return }
        let viewport = controller.viewport
        let visible = visibleEventIDs(on: backend, at: position, viewport: viewport)
        let allowed = Set(
            source.values
                .filter { $0.admittedAtSeconds <= position && viewport.shows($0, at: position) }
                .map(\.request.event.id)
        )
        #expect(visible.isSubset(of: allowed), sourceLocation: sourceLocation)
    }

    /// 没有在途准备，屏上的 placement 全部出自当前布局表，D 与之后半秒看得见的都与布局表一致。
    ///
    /// 上次对齐可能早于 D 不到一个覆盖区间，所以只采样到 D + 0.5：前瞻 2 秒仍覆盖它。
    private func isSettled(_ controller: DanmakuPresentationController) -> Bool {
        guard backend.pendingPreparationCount == 0, let position = clock.time else { return false }
        let table = controller.layoutTable
        let current = Dictionary(
            table.values.flatMap(\.placements).map { ($0.request.event.id, $0) }
        ) { first, _ in first }
        guard backend.installed.allSatisfy({ current[$0.key] == $0.value }) else { return false }
        let viewport = controller.viewport
        return [position, position + 0.5].allSatisfy { time in
            visibleEventIDs(on: backend, at: time, viewport: viewport)
                == expectedVisibleEventIDs(in: table, at: time, viewport: viewport)
        }
    }
}
