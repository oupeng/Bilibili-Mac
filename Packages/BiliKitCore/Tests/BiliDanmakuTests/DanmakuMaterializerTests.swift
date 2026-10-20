import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定 materializer 的契约：任一时刻在屏的 layer 恰好是布局表在该时刻、该取景框里可见的弹幕加前瞻；
/// seek 到任意时刻与从头连续推进到该时刻得到同一组 layer；布局表替换在一次调用里整屏换掉；迟到的纹理
/// 补上原 placement；清屏之后整屏重新挂上；换取景框的结果与一开始就用它相同。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuMaterializerTests {
    /// 与 `layoutTable` 默认规划画布同样大的窗口：整张布局表都在取景框里。
    private let fullViewport = viewport()
    @Test
    func layersAtATimeAreTheOnScreenSetPlusTheLookahead() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 500, seed: 31)])
        let backend = RecordingRenderingBackend()
        let materializer = DanmakuMaterializer(backend: backend)

        for position in stride(from: 0.0, through: 360, by: 11.3) {
            materializer.reconcile(
                table: table,
                position: position,
                viewport: fullViewport,
                staged: false
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
        let continuous = DanmakuMaterializer(backend: continuousBackend)
        for position in stride(
            from: 0.0,
            to: target,
            by: DanmakuPresentationController.reconcileStride
        ) {
            continuous.reconcile(
                table: table,
                position: position,
                viewport: fullViewport,
                staged: false
            )
        }
        continuous.reconcile(table: table, position: target, viewport: fullViewport, staged: false)

        let seekingBackend = RecordingRenderingBackend()
        let seeking = DanmakuMaterializer(backend: seekingBackend)
        seeking.reconcile(table: table, position: 600, viewport: fullViewport, staged: false)
        seeking.reconcile(table: table, position: target, viewport: fullViewport, staged: true)

        #expect(!seekingBackend.installed.isEmpty)
        #expect(seekingBackend.installed == continuousBackend.installed)
    }

    @Test
    func replacedTableSwapsTheWholeScreenInOneCall() {
        let events = denseEvents(segment: 1, count: 400, seed: 51)
        let narrow = layoutTable([1: events], surfaceWidth: 800)
        let wide = layoutTable([1: events], surfaceWidth: 1_400)
        let wideViewport = viewport(width: 1_400)
        let backend = RecordingRenderingBackend()
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: narrow, position: 120, viewport: fullViewport, staged: true)
        let before = backend.installed
        #expect(!before.isEmpty)

        // 新表里有旧屏上没有的弹幕：它们的纹理全部就绪之前，屏上原样不动。
        backend.delaysPreparation = true
        materializer.reconcile(table: wide, position: 120, viewport: wideViewport, staged: true)
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
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 200, viewport: fullViewport, staged: false)
        #expect(backend.installed.isEmpty)

        // 纹理到达时媒体时间已推进，弹幕仍按自己的时间点挂上，出现在中途应在的位置。
        materializer.reconcile(table: table, position: 200.5, viewport: fullViewport, staged: false)
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
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 90, viewport: fullViewport, staged: true)
        let before = backend.installed

        materializer.clear()
        #expect(backend.installed.isEmpty)
        materializer.reconcile(table: table, position: 90, viewport: fullViewport, staged: true)
        #expect(backend.installed == before)
    }

    /// 窗口换到另一块屏幕：已在屏的弹幕不先移除，新纹理全部就绪后一次原位替换。
    @Test
    func backingScaleChangeReplacesTexturesInPlaceInOneCall() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 81)])
        let backend = RecordingRenderingBackend()
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 150, viewport: fullViewport, staged: true)
        let before = backend.installed
        #expect(!before.isEmpty)

        backend.delaysPreparation = true
        materializer.setBackingScale(3)
        materializer.reconcile(table: table, position: 150, viewport: fullViewport, staged: true)
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
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 150, viewport: fullViewport, staged: true)

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
            DanmakuMaterializer(backend: backend).reconcile(
                table: table,
                position: 150,
                viewport: viewport,
                staged: true
            )
            return backend.installed
        }
        let backend = RecordingRenderingBackend()
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 150, viewport: small, staged: true)
        #expect(backend.installed == direct(small))

        materializer.reconcile(table: table, position: 150, viewport: large, staged: false)
        #expect(backend.installed == direct(large))
        let revealedInFlight = backend.installed.values.filter {
            $0.admittedAtSeconds < 150 && !small.showsLanes(of: $0)
        }
        #expect(!revealedInFlight.isEmpty)

        materializer.reconcile(table: table, position: 150, viewport: small, staged: false)
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
        let materializer = DanmakuMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 150, viewport: large, staged: true)
        let before = backend.installed

        backend.delaysPreparation = true
        materializer.reconcile(table: table, position: 151, viewport: large, staged: true)
        #expect(materializer.isCommitPending)
        materializer.reconcile(table: table, position: 151, viewport: small, staged: false)

        #expect(!backend.removedHistory.isEmpty)
        #expect(backend.installed.values.allSatisfy { small.shows($0, at: 151) })
        #expect(backend.installed.allSatisfy { before[$0.key] == $0.value })

        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(in: table, at: 151, viewport: small)
        #expect(backend.installed == placementsByID(expected))
    }

    private func placementsByID(
        _ placements: [DanmakuLanePlacement]
    ) -> [String: DanmakuLanePlacement] {
        Dictionary(uniqueKeysWithValues: placements.map { ($0.request.event.id, $0) })
    }
}
