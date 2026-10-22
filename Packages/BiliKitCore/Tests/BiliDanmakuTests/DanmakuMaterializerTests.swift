import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定 materializer 的契约：任一时刻在屏的 layer 恰好是布局表在该时刻、该取景框里可见的弹幕加前瞻；
/// seek 到任意时刻与从头连续推进到该时刻得到同一组 layer；跳到别处时缓存命中的纹理在同一次调用里挂上，
/// 其余各自就绪即出现，不为等别的弹幕扣住；整张重排的暂存在一次调用里整屏换掉，按 (时间, ID) 顺序挂上；
/// 迟到的纹理补上原 placement，是否挂上按纹理到达那一刻的显示时间判断，读不到显示时间时不挂上，有暂存就
/// 放弃它并交还全部准备；清屏之后重新挂上同一屏；换取景框的结果与一开始就用它相同；backing scale 变化
/// 必须在 backend 静默取消之后重开暂存，反过来暂存永远等不齐。
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
        seeking.reconcile(
            table: table,
            position: target,
            viewport: fullViewport,
            mode: .incremental
        )

        #expect(!seekingBackend.installed.isEmpty)
        #expect(seekingBackend.installed == continuousBackend.installed)
    }

    /// 跳到一半纹理还在缓存里、也有没命中的已进场弹幕的地方：命中的在同一次调用里全部出现，其余按任意
    /// 顺序逐条就绪，每就绪一条就出现，不等别的。
    @Test
    func jumpShowsCachedTexturesAtOnceAndTheRestAsEachBecomesReady() throws {
        let table = layoutTable(
            [1: denseEvents(segment: 1, count: 2_000, seed: 121)],
            surfaceWidth: 1_200,
            surfaceHeight: 720
        )
        let largeViewport = viewport(width: 1_200, height: 720)
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 60,
            viewport: largeViewport,
            mode: .incremental
        )
        #expect(!backend.installed.isEmpty)

        let desired = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 200,
            viewport: largeViewport
        )
        let cached = Set(
            desired.enumerated().filter { $0.offset % 2 == 0 }.map(\.element.request.event.id)
        )
        let uncachedAdmitted = desired.filter {
            !cached.contains($0.request.event.id) && $0.admittedAtSeconds <= 200
        }
        try #require(!uncachedAdmitted.isEmpty)
        backend.delaysPreparation = true
        backend.cachedEventIDs = cached

        materializer.reconcile(
            table: table,
            position: 200,
            viewport: largeViewport,
            mode: .incremental
        )
        #expect(backend.installedEventIDs == cached)
        expectNothingWithheld(on: backend, table: table, viewport: largeViewport, at: 200)
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations(1, reversed: true)
            expectNothingWithheld(on: backend, table: table, viewport: largeViewport, at: 200)
        }
        #expect(backend.installed == placementsByID(desired))
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
            mode: .incremental
        )
        let before = backend.installed
        #expect(!before.isEmpty)

        // 新表里有旧屏上没有的弹幕：它们的纹理全部就绪之前，屏上原样不动。
        backend.delaysPreparation = true
        materializer.reconcile(
            table: wide,
            position: 120,
            viewport: wideViewport,
            mode: .staged
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
            mode: .incremental
        )
        let before = backend.installed

        materializer.clear()
        #expect(backend.installed.isEmpty)
        materializer.reconcile(
            table: table,
            position: 90,
            viewport: fullViewport,
            mode: .incremental
        )
        #expect(backend.installed == before)
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
            mode: .staged
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
                mode: .incremental
            )
            return backend.installed
        }
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: small,
            mode: .incremental
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
            mode: .incremental
        )
        let before = backend.installed

        backend.delaysPreparation = true
        materializer.reconcile(
            table: table,
            position: 151,
            viewport: large,
            mode: .staged
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

    /// 纹理异步完成时读不到 D：不挂上；有暂存时放弃它，已就绪与在途的准备全部交还 backend，不占着名额。
    ///
    /// 正常到不了：读不到 D 之前总会先清屏。D 回来之后的下一次普通 reconcile 挂上此刻的集合。
    @Test(arguments: [true, false])
    func textureCompletedWithoutADisplayTimeWaitsForTheNextAlignment(staged: Bool) {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 63)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 120,
            viewport: fullViewport,
            mode: staged ? .staged : .incremental
        )
        #expect(materializer.isCommitPending == staged)
        backend.completePreparations(backend.pendingPreparationCount / 2)
        let installedBefore = backend.installed
        #expect(installedBefore.isEmpty == staged)

        materializer.clock.time = nil
        backend.completePreparations(1)
        #expect(!materializer.isCommitPending)
        #expect(backend.installed == installedBefore)
        #expect(backend.heldPreparationCount == 0)
        if staged {
            #expect(backend.pendingPreparationCount == 0)
        }
        backend.completePreparations()
        #expect(backend.installed == installedBefore)
        #expect(backend.heldPreparationCount == 0)

        materializer.reconcile(
            table: table,
            position: 120.4,
            viewport: fullViewport,
            mode: .incremental
        )
        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 120.4,
            viewport: fullViewport
        )
        #expect(backend.installed == placementsByID(expected))
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
            mode: .staged
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
            mode: .staged
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
