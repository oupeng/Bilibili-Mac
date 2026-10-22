import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现端在任意操作序列下的契约：D 前跳、回跳、推进，与 D 无关的快照，窗口 resize，backing scale
/// 变化，纹理乱序或部分完成，不论怎样交错，纹理全部完成之后看得见的集合都等于布局表在 D 时刻的样子，暂存
/// 不会卡住，屏上不残留离 D 超过一个覆盖区间的弹幕（在屏数量不随操作次数增长）。
///
/// 操作序列由固定种子生成，失败可以复现。布局表只在开头排一次：布局表替换在后台异步完成，序列执行中
/// 不让出主线程，backing scale 变化引起的后台重排在序列结束之前不会落地，结果不依赖调度时机；布局表替换
/// 与暂存的交错由控制器测试分别固定。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuPresentationRandomOperationTests {
    private static let operationCount = 500
    /// 排空纹理准备的轮数上限：一轮完成可能引出下一轮请求（提交后补做的普通对齐），远小于这个数就该收敛。
    private static let drainRoundLimit = 20
    /// D 能跳到的最远位置：超过两段已缓存的分段，落点可能没有弹幕。
    private static let farthestPosition = 760.0

    @Test
    func visibleSetFollowsTheDisplayTimeUnderRandomOperations() async {
        let identity = PlaybackItemIdentity(bvid: "BV1Random", cid: 1)
        let owner = UUID()
        let clock = ManualDisplayClock(time: 30)
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        controller.attachSurface(ownerID: owner, clock: clock)
        var scale = 2.0
        var window = (width: 800.0, height: 360.0)
        func updateSurface() {
            controller.updateSurface(
                width: window.width,
                height: window.height,
                screenWidth: 800,
                screenHeight: 360,
                backingScale: scale,
                ownerID: owner
            )
        }
        updateSurface()
        controller.apply(snapshot(identity: identity, position: 30, generation: 1, state: .paused))
        controller.setSegments(
            [
                1: denseEvents(segment: 1, count: 900, seed: 201),
                2: denseEvents(segment: 2, count: 900, seed: 202)
            ],
            for: identity
        )
        await backend.waitUntil { !backend.installed.isEmpty }
        backend.delaysPreparation = true

        var sequence = SeededSequence(seed: 500)
        func wake() {
            controller.displayClockDidChange(ownerID: owner)
        }
        func drainAndCheck() {
            var rounds = 0
            while backend.pendingPreparationCount > 0, rounds < Self.drainRoundLimit {
                backend.completePreparations(reversed: sequence.next() % 2 == 0)
                rounds += 1
            }
            #expect(backend.pendingPreparationCount == 0)
            let position = clock.time ?? 0
            // 上次对齐可能早于 D 不到一个覆盖区间，所以只采样到 D + 0.5：前瞻 2 秒仍覆盖它。
            let viewport = controller.viewport
            for time in [position, position + 0.5] {
                #expect(
                    visibleEventIDs(on: backend, at: time, viewport: viewport)
                        == expectedVisibleEventIDs(
                            in: controller.layoutTable,
                            at: time,
                            viewport: viewport
                        )
                )
            }
            let oldest = position - DanmakuPresentationController.alignmentCoverageSeconds
            let latest = position + DanmakuMaterializer.lookaheadSeconds
            #expect(
                backend.installed.values.allSatisfy {
                    controller.viewport.visibleUntil($0) > oldest && $0.admittedAtSeconds <= latest
                }
            )
        }

        for _ in 0..<Self.operationCount {
            let position = clock.time ?? 0
            switch sequence.next() % 6 {
            case 0:
                clock.time = position + 0.05 + sequence.unit() * 1.2
                wake()
            case 1:
                clock.time = sequence.unit() * Self.farthestPosition
                wake()
            case 2:
                clock.time = max(0, position - sequence.unit() * 2)
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
                window = windows[Int(sequence.next() % 3)]
                updateSurface()
            default:
                scale = scale == 2 ? 3 : 2
                updateSurface()
            }
            let pending = backend.pendingPreparationCount
            backend.completePreparations(
                Int(sequence.next() % UInt64(pending + 1)),
                reversed: sequence.next() % 2 == 0
            )
            if sequence.next() % 2 == 0 {
                drainAndCheck()
            }
        }
        drainAndCheck()
    }
}
