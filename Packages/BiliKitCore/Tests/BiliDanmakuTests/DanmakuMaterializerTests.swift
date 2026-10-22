import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定 materializer 的契约：任一时刻在屏的 layer 恰好是布局表在该时刻、该取景框里可见的弹幕加前瞻；
/// seek 到任意时刻与从头连续推进到该时刻得到同一组 layer；重新对齐时已进场缺纹理的不超过上限就逐条
/// 补上、超过就等齐一次替换；布局表替换在一次调用里整屏换掉，替换还在等纹理时的重新对齐（含极小回跳）
/// 也不拆开它；迟到的纹理补上原 placement，是否挂上按纹理到达那一刻的显示时间判断，读不到显示时间时
/// 只记下结果、不挂也不提交；清屏之后整屏重新挂上；换取景框的结果与一开始就用它相同；backing scale
/// 变化必须在 backend 静默取消之后重开暂存，反过来暂存永远等不齐。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuMaterializerTests {
    /// 与 `layoutTable` 默认规划画布同样大的窗口：整张布局表都在取景框里。
    private let fullViewport = viewport()
    @Test
    func layersAtATimeAreTheOnScreenSetPlusTheLookahead() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 500, seed: 31)])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)

        for position in stride(from: 0.0, through: 360, by: 11.3) {
            materializer.reconcile(
                table: table,
                position: position,
                viewport: fullViewport,
                mode: .incremental
            )
            let expected = table[1]?.placements.filter {
                $0.admittedAtSeconds <= position + DanmakuMaterializer.lookaheadSeconds
                    && $0.admittedAtSeconds + $0.request.durationSeconds > position
            }
            #expect(backend.installed == placementsByID(expected ?? []))
        }
    }

    @Test(arguments: [3.0, 47.5, 359.9, 365.0, 400.25])
    func seekingToATimeMatchesPlayingContinuouslyToIt(target: Double) {
        let table = layoutTable([
            1: denseEvents(segment: 1, count: 900, seed: 41),
            2: denseEvents(segment: 2, count: 900, seed: 42)
        ])
        let continuousBackend = RecordingRenderingBackend()
        let continuous = StoppedClockMaterializer(backend: continuousBackend)
        for position in stride(
            from: 0.0,
            to: target,
            by: DanmakuPresentationController.reconcileStride
        ) {
            continuous.reconcile(
                table: table,
                position: position,
                viewport: fullViewport,
                mode: .incremental
            )
        }
        continuous.reconcile(
            table: table,
            position: target,
            viewport: fullViewport,
            mode: .incremental
        )

        let seekingBackend = RecordingRenderingBackend()
        let seeking = StoppedClockMaterializer(backend: seekingBackend)
        seeking.reconcile(table: table, position: 600, viewport: fullViewport, mode: .incremental)
        seeking.reconcile(table: table, position: target, viewport: fullViewport, mode: .realign)

        #expect(!seekingBackend.installed.isEmpty)
        #expect(seekingBackend.installed == continuousBackend.installed)
    }

    @Test(arguments: [0, 1])
    func realignStagesOnlyWhenMoreThanTheLimitAreMissing(beyondLimit: Int) throws {
        let missing = DanmakuMaterializer.incrementalMissingTextureLimit + beyondLimit
        let events = (0..<missing).map {
            timedEvent(id: "missing-\($0)", time: 97 + Double($0) * 0.3)
        }
        let table = layoutTable([1: events])
        let admitted = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 100,
            viewport: fullViewport
        ).filter { $0.admittedAtSeconds <= 100 }
        try #require(admitted.count == missing)
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)

        materializer.reconcile(table: table, position: 100, viewport: fullViewport, mode: .realign)
        #expect(materializer.isCommitPending == (beyondLimit > 0))
        backend.completePreparations(1)
        #expect(backend.installed.count == (beyondLimit > 0 ? 0 : 1))
        backend.completePreparations()
        #expect(backend.installed.count == missing)
    }

    @Test
    func realignWithManyMissingTexturesReplacesTheScreenOnceReady() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 900, seed: 121)])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 60, viewport: fullViewport, mode: .realign)
        let before = backend.installed
        #expect(!before.isEmpty)

        backend.delaysPreparation = true
        materializer.reconcile(table: table, position: 200, viewport: fullViewport, mode: .realign)
        let waiting = backend.pendingPreparationCount
        #expect(waiting > DanmakuMaterializer.incrementalMissingTextureLimit)
        backend.completePreparations(waiting - 1)
        #expect(backend.installed == before)
        #expect(materializer.isCommitPending)

        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 200,
            viewport: fullViewport
        )
        #expect(backend.installed == placementsByID(expected))
    }

    @Test
    func replacedTableSwapsTheWholeScreenInOneCall() {
        let events = denseEvents(segment: 1, count: 400, seed: 51)
        let narrow = layoutTable([1: events], surfaceWidth: 800)
        let wide = layoutTable([1: events], surfaceWidth: 1_400)
        let wideViewport = viewport(width: 1_400)
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: narrow,
            position: 120,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        let before = backend.installed
        #expect(!before.isEmpty)

        // 新表里有旧屏上没有的弹幕：它们的纹理全部就绪之前，屏上原样不动。
        backend.delaysPreparation = true
        materializer.reconcile(
            table: wide,
            position: 120,
            viewport: wideViewport,
            mode: .staged(.wholeScreen)
        )
        let waiting = backend.pendingPreparationCount
        #expect(waiting > 1)
        backend.completePreparations(waiting - 1)
        #expect(backend.installed == before)
        #expect(materializer.isCommitPending)

        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: wide,
            at: 120,
            viewport: wideViewport
        )
        #expect(backend.installed == placementsByID(expected))
        #expect(!materializer.isCommitPending)
    }

    @Test(arguments: [119.99, 125])
    func realignKeepsAPendingTableReplacementWholeScreen(target: Double) {
        let events = denseEvents(segment: 1, count: 400, seed: 131)
        let narrow = layoutTable([1: events], surfaceWidth: 800)
        let wide = layoutTable([1: events], surfaceWidth: 1_400)
        let wideViewport = viewport(width: 1_400)
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: narrow,
            position: 120,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        let before = backend.installed
        #expect(!before.isEmpty)

        backend.delaysPreparation = true
        materializer.reconcile(
            table: wide,
            position: 120,
            viewport: wideViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(materializer.isCommitPending)
        materializer.reconcile(
            table: wide,
            position: target,
            viewport: wideViewport,
            mode: .realign
        )
        #expect(materializer.isCommitPending)
        #expect(backend.installed == before)

        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: wide,
            at: target,
            viewport: wideViewport
        )
        #expect(backend.installed == placementsByID(expected))
        #expect(!materializer.isCommitPending)
    }

    @Test
    func realignSupersedesAPendingSegmentArrival() {
        let first = denseEvents(segment: 1, count: 300, seed: 141)
        let second = denseEvents(segment: 2, count: 900, seed: 142)
        let withoutSecond = layoutTable([1: first])
        let withSecond = layoutTable([1: first, 2: second])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: withoutSecond,
            position: 400,
            viewport: fullViewport,
            mode: .realign
        )
        #expect(backend.installed.isEmpty)

        backend.delaysPreparation = true
        materializer.reconcile(
            table: withSecond,
            position: 400,
            viewport: fullViewport,
            mode: .staged(.supersedable)
        )
        #expect(materializer.isCommitPending)
        backend.completePreparations(backend.pendingPreparationCount / 2)
        #expect(backend.installed.isEmpty)

        materializer.reconcile(
            table: withSecond,
            position: 401.6,
            viewport: fullViewport,
            mode: .realign
        )
        let expected = placementsByID(
            DanmakuMaterializer.desiredPlacements(in: withSecond, at: 401.6, viewport: fullViewport)
        )
        #expect(!backend.installed.isEmpty)
        #expect(backend.installed.allSatisfy { expected[$0.key] == $0.value })

        backend.completePreparations()
        #expect(backend.installed == expected)
    }

    @Test
    func lateTextureAppearsWithItsOriginalPlacement() throws {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 61)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 200,
            viewport: fullViewport,
            mode: .incremental
        )
        #expect(backend.installed.isEmpty)

        // 纹理到达时媒体时间已推进，弹幕仍按自己的时间点挂上，出现在中途应在的位置。
        materializer.reconcile(
            table: table,
            position: 200.5,
            viewport: fullViewport,
            mode: .incremental
        )
        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 200.5,
            viewport: fullViewport
        )
        #expect(backend.installed == placementsByID(expected))
        let midway = try #require(expected.first { $0.admittedAtSeconds < 200 })
        #expect(
            backend.installed[midway.request.event.id]?.admittedAtSeconds
                == midway.admittedAtSeconds
        )
    }

    @Test
    func clearingAndReconcilingAgainRestoresTheSameScreen() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 71)])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 90,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        let before = backend.installed

        materializer.clear()
        #expect(backend.installed.isEmpty)
        materializer.reconcile(
            table: table,
            position: 90,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(backend.installed == before)
    }

    /// 窗口换到另一块屏幕：已在屏的弹幕不先移除，新纹理全部就绪后一次原位替换。
    @Test
    func backingScaleChangeReplacesTexturesInPlaceInOneCall() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 81)])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        let before = backend.installed
        #expect(!before.isEmpty)

        backend.delaysPreparation = true
        materializer.setBackingScale(3)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(backend.pendingPreparationCount == before.count)
        backend.completePreparations(before.count - 1)
        #expect(backend.installed == before)
        #expect(backend.replacedHistory.isEmpty)

        backend.completePreparations()
        #expect(backend.installed == before)
        #expect(Set(backend.replacedHistory) == Set(before.keys))
        #expect(backend.removedHistory.isEmpty)
    }

    /// 暂存提交按 (时间, ID) 顺序挂上，与纹理完成的先后无关。
    @Test
    func stagedCommitInstallsInTimeOrder() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 91)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )

        backend.completePreparations(reversed: true)
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 150,
            viewport: fullViewport
        )
        #expect(backend.installedHistory == expected.map(\.request.event.id))
    }

    /// 窗口放大与缩小都只按新取景框增删：结果与一开始就用这个窗口相同，放大时补上的包括已在飞行
    /// 途中的弹幕（按原 placement 挂上，位置由同一份运动决定），缩小时裁掉的被移除。
    @Test
    func resizingMatchesStartingWithTheNewWindow() {
        let table = layoutTable(
            [1: denseEvents(segment: 1, count: 900, seed: 101)],
            surfaceWidth: 1_200,
            surfaceHeight: 720
        )
        let large = viewport(width: 1_200, height: 720)
        let small = viewport(width: 500, height: 200)
        func direct(_ viewport: DanmakuViewport) -> [String: DanmakuLanePlacement] {
            let backend = RecordingRenderingBackend()
            StoppedClockMaterializer(backend: backend).reconcile(
                table: table,
                position: 150,
                viewport: viewport,
                mode: .staged(.wholeScreen)
            )
            return backend.installed
        }
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: small,
            mode: .staged(.wholeScreen)
        )
        #expect(backend.installed == direct(small))

        materializer.reconcile(table: table, position: 150, viewport: large, mode: .incremental)
        #expect(backend.installed == direct(large))
        let revealedInFlight = backend.installed.values.filter {
            $0.admittedAtSeconds < 150 && !small.showsLanes(of: $0)
        }
        #expect(!revealedInFlight.isEmpty)

        materializer.reconcile(table: table, position: 150, viewport: small, mode: .incremental)
        #expect(backend.installed == direct(small))
        #expect(!backend.removedHistory.isEmpty)
    }

    /// 暂存提交还在等纹理时缩小窗口：取景框外已挂上的弹幕立即移除，屏上不换成新 placement；提交后
    /// 与一开始就用小窗口相同。
    @Test
    func shrinkingDuringAStagedCommitRemovesOutsideLayersAtOnce() {
        let table = layoutTable(
            [1: denseEvents(segment: 1, count: 900, seed: 111)],
            surfaceWidth: 1_200,
            surfaceHeight: 720
        )
        let large = viewport(width: 1_200, height: 720)
        let small = viewport(width: 1_200, height: 200)
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: large,
            mode: .staged(.wholeScreen)
        )
        let before = backend.installed

        backend.delaysPreparation = true
        materializer.reconcile(
            table: table,
            position: 151,
            viewport: large,
            mode: .staged(.wholeScreen)
        )
        #expect(materializer.isCommitPending)
        materializer.reconcile(table: table, position: 151, viewport: small, mode: .incremental)

        #expect(!backend.removedHistory.isEmpty)
        #expect(backend.installed.values.allSatisfy { small.shows($0, at: 151) })
        #expect(backend.installed.allSatisfy { before[$0.key] == $0.value })

        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(in: table, at: 151, viewport: small)
        #expect(backend.installed == placementsByID(expected))
    }

    /// 纹理到达时显示时间已走到这些弹幕都离场之后：按此刻的 D 判断，一条也不挂。
    @Test
    func lateTextureIsJudgedAtTheCurrentDisplayTime() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 62)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 200,
            viewport: fullViewport,
            mode: .incremental
        )
        #expect(backend.pendingPreparationCount > 0)

        materializer.clock.time = 300
        backend.completePreparations()

        #expect(backend.installed.isEmpty)
    }

    /// 纹理异步完成时读不到 D：普通准备不挂上，暂存不提交但照常扣减等待集合；D 回来之后，不论是重新对齐
    /// 还是接连两次普通 reconcile，都用已就绪的纹理一次整屏挂上，不会一直等下去。
    @Test(arguments: [true, false])
    func stageCompletedWithoutADisplayTimeCommitsOnceTheTimeReturns(realigns: Bool) {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 63)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 120,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(materializer.isCommitPending)

        materializer.clock.time = nil
        backend.completePreparations()
        #expect(backend.installed.isEmpty)
        #expect(materializer.isCommitPending)

        if realigns {
            materializer.reconcile(
                table: table,
                position: 120,
                viewport: fullViewport,
                mode: .realign
            )
        } else {
            for position in [120.0, 120.4] {
                materializer.reconcile(
                    table: table,
                    position: position,
                    viewport: fullViewport,
                    mode: .incremental
                )
            }
        }
        #expect(!materializer.isCommitPending)
        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: realigns ? 120 : 120.4,
            viewport: fullViewport
        )
        #expect(backend.installedEventIDs == Set(expected.map(\.request.event.id)))
    }

    /// backing scale 在读不到 D 时变化（正常到不了：读不到 D 之前总会先清屏）：放弃等待中的暂存，不按旧时间
    /// 重开；D 回来后的普通 reconcile 按新 scale 准备并挂上此刻的集合。
    @Test
    func backingScaleChangeWithoutADisplayTimeDropsThePendingStage() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 65)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(materializer.isCommitPending)

        materializer.clock.time = nil
        backend.updateSurfaceSize(width: 800, height: 360, backingScale: 3)
        materializer.setBackingScale(3)
        #expect(!materializer.isCommitPending)
        #expect(backend.pendingPreparationCount == 0)

        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .incremental
        )
        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 150,
            viewport: fullViewport
        )
        #expect(backend.installed == placementsByID(expected))
    }

    /// backing scale 变化的顺序契约：backend 先静默取消在途准备，materializer 再按此刻的 D 重开暂存，纹理
    /// 齐了就提交；反过来，重开发出的请求被随后的取消吞掉，暂存永远等不齐。
    @Test(arguments: [true, false])
    func backingScaleRestartMustFollowTheBackendsSilentCancel(backendFirst: Bool) {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 64)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: fullViewport,
            mode: .staged(.wholeScreen)
        )
        #expect(materializer.isCommitPending)

        if backendFirst {
            backend.updateSurfaceSize(width: 800, height: 360, backingScale: 3)
            materializer.setBackingScale(3)
        } else {
            materializer.setBackingScale(3)
            backend.updateSurfaceSize(width: 800, height: 360, backingScale: 3)
        }
        backend.completePreparations()

        #expect(materializer.isCommitPending == !backendFirst)
        #expect(backend.installed.isEmpty == !backendFirst)
    }

    private func placementsByID(
        _ placements: [DanmakuLanePlacement]
    ) -> [String: DanmakuLanePlacement] {
        Dictionary(uniqueKeysWithValues: placements.map { ($0.request.event.id, $0) })
    }
}

/// 显示时间停在最近一次 reconcile 位置的 materializer。
///
/// 这些测试里时间不自己走：纹理异步完成时 materializer 读到的 D 就是最近一次 reconcile 传入的位置；要让 D
/// 在两次 reconcile 之间移动或读不到的测试直接改 `clock`。
@MainActor
private final class StoppedClockMaterializer {
    let clock: ManualDisplayClock
    let materializer: DanmakuMaterializer

    init(backend: RecordingRenderingBackend) {
        let clock = ManualDisplayClock()
        self.clock = clock
        materializer = DanmakuMaterializer(backend: backend) { clock.time }
    }

    var isCommitPending: Bool { materializer.isCommitPending }

    func reconcile(
        table: [Int: DanmakuSegmentLayout],
        position: Double,
        viewport: DanmakuViewport,
        mode: DanmakuMaterializer.Mode
    ) {
        clock.time = position
        materializer.reconcile(table: table, position: position, viewport: viewport, mode: mode)
    }

    func setBackingScale(_ scale: Double) {
        materializer.setBackingScale(scale, at: clock.time)
    }

    func clear() {
        materializer.clear()
    }
}
