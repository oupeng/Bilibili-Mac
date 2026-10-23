import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定 materializer 的契约：任一时刻在屏的 layer 恰好是布局表在该时刻、该取景框里可见的弹幕加前瞻；
/// seek 到任意时刻与从头连续推进到该时刻得到同一组 layer；跳到别处时缓存命中的纹理在同一次调用里挂上，
/// 其余各自就绪即出现，不为等别的弹幕扣住；布局表替换在同一次调用里把在屏的全部换到新车道；迟到的纹理
/// 补上原 placement，是否挂上按纹理到达那一刻的显示时间判断，读不到显示时间时不挂上并交还；清屏之后重新
/// 挂上同一屏；换取景框的结果与一开始就用它相同；换 backing scale 时 materializer 自己不发请求，与 backend
/// 谁先换都收敛到全部新 scale 的纹理；在某个 scale 下纹理超限的弹幕在该 scale 下不反复请求，换到放得下它
/// 的 scale 后照常出现。
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
                viewport: fullViewport
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
                viewport: fullViewport
            )
        }
        continuous.reconcile(
            table: table,
            position: target,
            viewport: fullViewport
        )

        let seekingBackend = RecordingRenderingBackend()
        let seeking = StoppedClockMaterializer(backend: seekingBackend)
        seeking.reconcile(table: table, position: 600, viewport: fullViewport)
        seeking.reconcile(
            table: table,
            position: target,
            viewport: fullViewport
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
            viewport: largeViewport
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
            viewport: largeViewport
        )
        #expect(backend.installedEventIDs == cached)
        expectNothingWithheld(on: backend, table: table, viewport: largeViewport, at: 200)
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations(1, reversed: true)
            expectNothingWithheld(on: backend, table: table, viewport: largeViewport, at: 200)
        }
        #expect(backend.installed == placementsByID(desired))
    }

    /// 布局表替换（换车道）：同一次调用里在屏的全部换成新表的 placement，纹理已在缓存里的新弹幕同时出现，
    /// 其余逐条就绪即出现；任何时刻屏上都只出自新表。
    @Test
    func replacedTableMovesTheScreenToItsLanesInOneCall() {
        let events = denseEvents(segment: 1, count: 400, seed: 51)
        let narrow = layoutTable([1: events], surfaceWidth: 800)
        let wide = layoutTable([1: events], surfaceWidth: 1_400)
        let wideViewport = viewport(width: 1_400)
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(table: narrow, position: 120, viewport: fullViewport)
        let before = backend.installed
        #expect(!before.isEmpty)

        let desired = placementsByID(
            DanmakuMaterializer.desiredPlacements(in: wide, at: 120, viewport: wideViewport)
        )
        let appearing = desired.keys.filter { before[$0] == nil }.sorted()
        #expect(appearing.count > 1)
        backend.delaysPreparation = true
        backend.cachedEventIDs = Set(appearing.prefix(appearing.count / 2))
        let wideByID = placementsByEventID(wide)
        func expectOnlyTheNewLanes() {
            #expect(backend.installed.allSatisfy { wideByID[$0.key] == $0.value })
            expectNothingWithheld(on: backend, table: wide, viewport: wideViewport, at: 120)
        }

        materializer.reconcile(table: wide, position: 120, viewport: wideViewport)
        #expect(backend.cachedEventIDs.isSubset(of: backend.installedEventIDs))
        expectOnlyTheNewLanes()
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations(1)
            expectOnlyTheNewLanes()
        }
        #expect(backend.installed == desired)
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
            viewport: fullViewport
        )
        #expect(backend.installed.isEmpty)

        // 纹理到达时媒体时间已推进，弹幕仍按自己的时间点挂上，出现在中途应在的位置。
        materializer.reconcile(
            table: table,
            position: 200.5,
            viewport: fullViewport
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
            viewport: fullViewport
        )
        let before = backend.installed

        materializer.clear()
        #expect(backend.installed.isEmpty)
        materializer.reconcile(
            table: table,
            position: 90,
            viewport: fullViewport
        )
        #expect(backend.installed == before)
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
                viewport: viewport
            )
            return backend.installed
        }
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(
            table: table,
            position: 150,
            viewport: small
        )
        #expect(backend.installed == direct(small))

        materializer.reconcile(table: table, position: 150, viewport: large)
        #expect(backend.installed == direct(large))
        let revealedInFlight = backend.installed.values.filter {
            $0.admittedAtSeconds < 150 && !small.showsLanes(of: $0)
        }
        #expect(!revealedInFlight.isEmpty)

        materializer.reconcile(table: table, position: 150, viewport: small)
        #expect(backend.installed == direct(small))
        #expect(!backend.removedHistory.isEmpty)
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
            viewport: fullViewport
        )
        #expect(backend.pendingPreparationCount > 0)

        materializer.clock.time = 300
        backend.completePreparations()

        #expect(backend.installed.isEmpty)
    }

    /// 纹理异步完成时读不到 D：不挂上，交还 backend，不占着名额。
    ///
    /// 正常到不了：读不到 D 之前总会先清屏。D 回来之后的下一次 reconcile 挂上此刻的集合。
    @Test
    func textureCompletedWithoutADisplayTimeWaitsForTheNextAlignment() {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 63)])
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 120, viewport: fullViewport)
        backend.completePreparations(backend.pendingPreparationCount / 2)
        let installedBefore = backend.installed
        #expect(!installedBefore.isEmpty)

        materializer.clock.time = nil
        backend.completePreparations()
        #expect(backend.installed == installedBefore)
        #expect(backend.heldPreparationCount == 0)

        materializer.reconcile(table: table, position: 120.4, viewport: fullViewport)
        backend.completePreparations()
        let expected = DanmakuMaterializer.desiredPlacements(
            in: table,
            at: 120.4,
            viewport: fullViewport
        )
        #expect(backend.installed == placementsByID(expected))
    }

    /// backing scale 变化的顺序契约是「backend 换 scale 与 materializer 换 scale 之间不发准备请求」：materializer
    /// 换 scale 只作废在途记录、自己不发请求，所以两步谁先谁后都一样，之后的 reconcile 把在屏的全部原位换成
    /// 新 scale 的纹理。
    @Test(arguments: [true, false])
    func backingScaleChangeIssuesNoRequestsSoEitherOrderConverges(backendFirst: Bool) {
        let table = layoutTable([1: denseEvents(segment: 1, count: 300, seed: 64)])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        materializer.reconcile(table: table, position: 150, viewport: fullViewport)
        #expect(!backend.installed.isEmpty)
        backend.delaysPreparation = true
        materializer.reconcile(table: table, position: 155, viewport: fullViewport)
        #expect(backend.pendingPreparationCount > 0)

        if backendFirst {
            backend.updateSurfaceSize(width: 800, height: 360, backingScale: 3)
            materializer.setBackingScale(3)
        } else {
            materializer.setBackingScale(3)
            backend.updateSurfaceSize(width: 800, height: 360, backingScale: 3)
        }
        #expect(backend.pendingPreparationCount == 0)

        materializer.reconcile(table: table, position: 155, viewport: fullViewport)
        backend.completePreparations()
        let expected = placementsByID(
            DanmakuMaterializer.desiredPlacements(in: table, at: 155, viewport: fullViewport)
        )
        #expect(backend.installed == expected)
        #expect(backend.textureScales.values.allSatisfy { $0 == 3 })
    }

    /// 纹理超限按像素算、与 backing scale 有关：在 2x 下被拒的长弹幕，同一 scale 下不再请求；换到放得下它的
    /// 1x 后，布局表一含它就重新请求并出现。
    @Test
    func oversizedTextureIsRequestedAgainAtAScaleThatFitsIt() throws {
        let long = longTextEvent(id: "long", time: 100)
        try #require(fitsTexture(long, backingScale: 1))
        try #require(!fitsTexture(long, backingScale: 2))
        let table = layoutTable([1: [long]])
        let backend = RecordingRenderingBackend()
        let materializer = StoppedClockMaterializer(backend: backend)
        func setBackingScale(_ scale: Double) {
            backend.updateSurfaceSize(width: 800, height: 360, backingScale: scale)
            materializer.setBackingScale(scale)
        }
        setBackingScale(1)
        materializer.reconcile(table: table, position: 100.5, viewport: fullViewport)
        try #require(backend.textureScales[long.id] == 1)

        // 新 scale 的表落地之前，旧表按新 scale 对齐：2x 纹理被拒，这一 scale 下只请求一次。
        setBackingScale(2)
        let requestsBefore = backend.preparationHistory.count
        materializer.reconcile(table: table, position: 100.5, viewport: fullViewport)
        materializer.reconcile(table: table, position: 100.6, viewport: fullViewport)
        #expect(backend.preparationHistory.dropFirst(requestsBefore) == [long.id])
        // 2x 的表测量时排除了它。
        materializer.reconcile(table: [:], position: 100.6, viewport: fullViewport)
        #expect(backend.installed.isEmpty)

        setBackingScale(1)
        materializer.reconcile(table: table, position: 100.7, viewport: fullViewport)
        #expect(backend.textureScales[long.id] == 1)
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

    func reconcile(
        table: [Int: DanmakuSegmentLayout],
        position: Double,
        viewport: DanmakuViewport
    ) {
        clock.time = position
        materializer.reconcile(table: table, position: position, viewport: viewport)
    }

    func setBackingScale(_ scale: Double) {
        materializer.setBackingScale(scale)
    }

    func clear() {
        materializer.clear()
    }
}
