import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现控制器的契约：位置一律是宿主时钟层的显示时间 D，快照只是检查节拍，时钟写入不等快照也会
/// 重新检查，读不到 D 时什么都不挂；画面在分段布局完成后按 D 整屏出现，看得见的集合与布局表在 D 时刻
/// 一致；何时对齐只看 D 是否越出上次对齐的覆盖区间（含回跳），区间长于步长、不超过前瞻，区间内的跳变
/// 什么都不做；跳到纹理已缓存的地方在一次调用里整屏换成那一刻的样子；连续拖动时已就绪的纹理每一步都
/// 挂上，拖进未缓存区域、分段陆续到达时也一样，停下后补齐落点（落点分段未到时不留旧画面）；整屏暂存
/// 等纹理时 D 回跳不拆开它；关闭弹幕清屏、打开恢复；设置变化整屏换成新布局；换视频清屏；换 item 只接受
/// 当前 owner，清屏后直到新 item 的快照与新时钟纪元的 D 都有了才按原布局表挂回；切视频时旧 item 解绑后、
/// 新 item 有时间之前什么都不挂；旧 surface owner 的操作
/// 与唤醒无效；窗口尺寸变化不重排、立即按新取景框增删，屏幕尺寸变化整张重排。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuPresentationControllerTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1Controller", cid: 1)
    /// 宿主时钟层发布的 D，每个测试一份；`move` 让它与快照位置一致，分歧测试单独让两者分开。
    private let clock = ManualDisplayClock()

    @Test
    func screenAppearsOnceTheSegmentIsLaidOut() async {
        let (controller, backend) = makeController()
        move(controller, to: 30, generation: 1, state: .paused)
        controller.setSegments([1: events()], for: identity)

        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        expectVisibility(in: controller, backend, at: 30)
    }

    @Test
    func everyJumpOutOfTheCoveredSpanAlignsTheScreenAtOnce() async {
        let (controller, backend) = await laidOutController(at: 30)
        let clearCount = backend.clearCount

        for position in [120.0, 160, 200] {
            move(controller, to: position, generation: 1)
            #expect(backend.installedEventIDs == expectedIDs(at: position, in: controller))
            expectVisibility(in: controller, backend, at: position)
        }
        #expect(backend.clearCount == clearCount)
    }

    @Test
    func draggingKeepsInstallingReadyTextures() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true

        let steps = Array(stride(from: 120.0, to: 140, by: 1.6))
        for (index, position) in steps.enumerated() {
            move(controller, to: position, generation: 1)
            let expected = expectedIDs(at: position, in: controller)
            if index > 0 {
                #expect(!backend.installed.isEmpty)
                #expect(backend.installedEventIDs.isSubset(of: expected))
            }
            backend.completePreparations(backend.pendingPreparationCount / 2)
        }
        backend.completePreparations()

        let last = steps[steps.count - 1]
        #expect(backend.installedEventIDs == expectedIDs(at: last, in: controller))
        expectVisibility(in: controller, backend, at: last)
    }

    /// 落点分段还没到：按新时刻对齐（旧时刻的弹幕全部移走），分段到达后整屏挂上。
    @Test
    func draggingIntoUncachedSegmentsKeepsFollowing() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true
        let second = denseEvents(segment: 2, count: 900, seed: 151)
        let third = denseEvents(segment: 3, count: 900, seed: 152)
        func step(to position: Double) {
            move(controller, to: position, generation: 1)
            #expect(!backend.installed.isEmpty)
            #expect(
                backend.installedEventIDs.isSubset(of: expectedIDs(at: position, in: controller))
            )
            backend.completePreparations(backend.pendingPreparationCount / 2)
        }

        for (segments, start) in [
            ([1: events(), 2: second], 400.0), ([1: events(), 2: second, 3: third], 730)
        ] {
            move(controller, to: start, generation: 1)
            #expect(backend.installed.isEmpty)
            let waiting = backend.pendingPreparationCount
            controller.setSegments(segments, for: identity)
            await backend.waitUntil { backend.pendingPreparationCount > waiting }
            backend.completePreparations(backend.pendingPreparationCount / 2)
            for offset in [1.6, 3.2, 4.8] {
                step(to: start + offset)
            }
        }
        backend.completePreparations()

        #expect(backend.installedEventIDs == expectedIDs(at: 734.8, in: controller))
        expectVisibility(in: controller, backend, at: 734.8)
    }

    @Test
    func farSeekShowsNothingStaleUntilItsSegmentArrives() async {
        let (controller, backend) = await laidOutController(at: 30)

        move(controller, to: 1_000, generation: 2, state: .paused)
        #expect(backend.installed.isEmpty)

        let far = (0..<200).map { timedEvent(id: "far-\($0)", time: 990 + Double($0) * 0.1) }
        controller.setSegments([1: events(), 3: far], for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 1_000, in: controller))
        #expect(backend.installedEventIDs.allSatisfy { $0.hasPrefix("far-") })
        expectVisibility(in: controller, backend, at: 1_000)
    }

    @Test
    func coveredSpanLiesBetweenTheStrideAndTheLookahead() {
        #expect(
            DanmakuPresentationController.reconcileStride
                < DanmakuPresentationController.alignmentCoverageSeconds
        )
        #expect(
            DanmakuPresentationController.alignmentCoverageSeconds
                <= DanmakuMaterializer.lookaheadSeconds
        )
    }

    @Test
    func jumpInsideTheCoveredSpanDoesNothing() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true
        let before = backend.installed
        let removed = backend.removedHistory.count
        let clearCount = backend.clearCount

        move(controller, to: 30.9, generation: 2)
        #expect(backend.installed == before)
        #expect(backend.removedHistory.count == removed)
        #expect(backend.pendingPreparationCount == 0)
        #expect(backend.clearCount == clearCount)
    }

    @Test
    func jumpingBackRealignsEvenBySmallAmounts() async throws {
        let (controller, backend) = await laidOutController(at: 30)
        let target = 29.7
        try #require(expectedIDs(at: target, in: controller) != backend.installedEventIDs)

        move(controller, to: target, generation: 1)
        #expect(backend.installedEventIDs == expectedIDs(at: target, in: controller))
        expectVisibility(in: controller, backend, at: target)
    }

    /// 暂停中 seek：时钟层跳到新位置后不等快照，写入通知就按新的 D 整屏对齐；别的 owner 的通知无效。
    @Test
    func clockJumpRealignsWithoutASnapshot() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        clock.time = 120
        controller.displayClockDidChange(ownerID: UUID())
        #expect(backend.installed == before)

        controller.displayClockDidChange(ownerID: owner)
        #expect(backend.installedEventIDs == expectedIDs(at: 120, in: controller))
        expectVisibility(in: controller, backend, at: 120)
    }

    /// 回归护栏：快照回跳或领先（seek 起播、未缓冲拖动、4x 跳变风暴）而 D 不动时，屏上集合一条不变，
    /// 看得见的仍是布局表在 D 时刻的样子。
    @Test(arguments: [29.7, 25.0, 31.6, 75.0])
    func snapshotDivergingFromTheClockKeepsTheScreen(snapshotPosition: Double) async throws {
        let (controller, backend) = await laidOutController(at: 30)
        try #require(expectedIDs(at: snapshotPosition, in: controller) != backend.installedEventIDs)
        let before = backend.installed
        let removed = backend.removedHistory.count

        controller.apply(snapshot(identity: identity, position: snapshotPosition, generation: 2))

        #expect(backend.installed == before)
        #expect(backend.removedHistory.count == removed)
        expectVisibility(in: controller, backend, at: 30)
    }

    /// 快照回跳 2ms 而 D 不动时什么都不做，分段到达的可取代暂存还在等纹理时也一样。
    ///
    /// 按快照判断的话，这次回跳越出覆盖区间、触发重新对齐，取代这次暂存，把已就绪的那部分先挂上。
    @Test
    func snapshotTwitchDuringASupersedableStageChangesNothing() async {
        let (controller, backend) = await laidOutController(at: 365)
        backend.delaysPreparation = true
        let waiting = backend.pendingPreparationCount
        controller.setSegments(
            [1: events(), 2: denseEvents(segment: 2, count: 900, seed: 153)],
            for: identity
        )
        await backend.waitUntil { backend.pendingPreparationCount > waiting }
        backend.completePreparations(backend.pendingPreparationCount / 2)
        let history = ScreenHistory(backend)

        controller.apply(snapshot(identity: identity, position: 364.998, generation: 2))

        #expect(ScreenHistory(backend) == history)
        backend.completePreparations()
        expectVisibility(in: controller, backend, at: 365)
    }

    /// 切视频时，新 item 有时间之前什么都不挂。
    ///
    /// 旧 item 解绑后时钟读不到 D（没有 item 就没有时间）。新视频的快照与分段在新 item 有时间之前到达，
    /// 不会按旧视频的时刻冻结在黑屏上；新 item 的 D 到了才按它的时刻挂上。
    @Test
    func switchingVideosShowsNothingUntilTheNewItemHasATime() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 300, surfaceOwner: owner)
        let next = PlaybackItemIdentity(bvid: "BV1NextVideo", cid: 2)

        controller.playerItemWillChange(ownerID: owner)
        clock.time = nil
        controller.apply(snapshot(identity: next, position: 0, generation: 1, state: .loading))
        controller.setSegments([1: events()], for: next)
        while controller.layoutTable.isEmpty {
            await Task.yield()
        }
        #expect(backend.installed.isEmpty)

        clock.time = 0
        controller.displayClockDidChange(ownerID: owner)
        #expect(!backend.installed.isEmpty)
        #expect(backend.installedEventIDs == expectedIDs(at: 0, in: controller))
    }

    /// 整屏暂存（设置重排）还在等纹理时 D 往回跳，暂存不被拆开。
    ///
    /// D 往回跳来自速率 0 时往回 seek、在时钟层的等待窗口里暂停：只在新集合上继续整屏暂存，旧表的画面一条
    /// 不动；纹理齐了之后一次换成新表在新 D 的样子。拆开的话就是新旧表混排。
    @Test
    func clockJumpingBackDuringAWholeScreenStageDoesNotSplitIt() async {
        let owner = UUID()
        let (controller, backend) = await stagingRelayout(owner: owner)
        backend.completePreparations(backend.pendingPreparationCount / 2)
        let history = ScreenHistory(backend)

        for position in [29.7, 29.0] {
            clock.time = position
            controller.displayClockDidChange(ownerID: owner)
            #expect(ScreenHistory(backend) == history)
        }

        drainRelayout(controller, backend, at: 29.0)
    }

    @Test
    func disablingClearsAndEnablingRestoresTheCurrentTime() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.setEnabled(false)
        #expect(backend.installed.isEmpty)
        move(controller, to: 45, generation: 1, state: .paused)
        #expect(backend.installed.isEmpty)

        controller.setEnabled(true)
        #expect(backend.installedEventIDs == expectedIDs(at: 45, in: controller))
        expectVisibility(in: controller, backend, at: 45)
    }

    @Test
    func settingsChangeReplacesTheScreenWithTheNewLayout() async {
        let (controller, backend) = await laidOutController(at: 30)
        let before = backend.installed

        controller.setSpeedLevel(.one)
        await backend.waitUntil { backend.installed != before }
        let expected = DanmakuMaterializer.desiredPlacements(
            in: controller.layoutTable,
            at: 30,
            viewport: controller.viewport
        )
        #expect(expected.allSatisfy { backend.installed[$0.request.event.id] == $0 })
        #expect(backend.installed.count == expected.count)
    }

    @Test
    func newIdentityClearsTheScreen() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.apply(
            snapshot(
                identity: PlaybackItemIdentity(bvid: "BV1Other", cid: 2),
                position: 0,
                generation: 1
            )
        )
        #expect(backend.installed.isEmpty)
        controller.setSegments([1: events()], for: identity)
        #expect(controller.layoutTable.isEmpty)
    }

    /// 换 item 前只有当前 surface owner 能清屏；别的 owner 调用无效，画面不动。
    @Test
    func playerItemChangeFromAnotherOwnerIsIgnored() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed
        let clearCount = backend.clearCount

        controller.playerItemWillChange(ownerID: UUID())
        #expect(backend.installed == before)
        #expect(backend.clearCount == clearCount)
    }

    /// 同一视频换线路或清晰度：换 item 时清屏、保留布局表；时钟换绑后新纪元还没写入（D 读不到）时 resize
    /// 不挂回；新 item 的快照与新纪元的 D 只到一个都不挂，两个都到了（不论先后）才按原布局表整屏挂回。
    @Test(arguments: [true, false])
    func playerItemChangeWaitsForTheNewSnapshotAndTheNewClockEpoch(snapshotFirst: Bool) async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        controller.playerItemWillChange(ownerID: owner)
        clock.time = nil
        #expect(backend.installed.isEmpty)
        let window = Size(width: 800, height: 360)
        resize(controller, owner: owner, window: window, screen: window)
        #expect(backend.installed.isEmpty)

        if snapshotFirst {
            controller.apply(pausedSnapshot(at: 30))
            #expect(backend.installed.isEmpty)
            clock.time = 30
            controller.displayClockDidChange(ownerID: owner)
        } else {
            clock.time = 30
            controller.displayClockDidChange(ownerID: owner)
            #expect(backend.installed.isEmpty)
            controller.apply(pausedSnapshot(at: 30))
        }
        #expect(backend.installed == before)
    }

    @Test
    func staleSurfaceOwnerCannotResizeDetachOrWake() async {
        let (controller, backend) = makeController()
        let first = UUID()
        let second = UUID()
        controller.attachSurface(ownerID: first, clock: clock)
        controller.attachSurface(ownerID: second, clock: clock)

        let sizesBefore = backend.surfaceSizes.count
        controller.updateSurface(
            width: 10,
            height: 10,
            screenWidth: 10,
            screenHeight: 10,
            backingScale: 2,
            ownerID: first
        )
        #expect(backend.surfaceSizes.count == sizesBefore)
        #expect(!controller.detachSurface(ownerID: first))
        #expect(controller.detachSurface(ownerID: second))
        #expect(backend.stopCount == 0)
    }

    /// 窗口缩小与放大都不重排：布局表与一开始就用小窗口时相同；增删当场按新取景框完成，不清屏；
    /// 放大后的画面与一直是大窗口时相同，新露出的、正在飞的弹幕按原 placement 挂上。
    @Test
    func resizingKeepsTheTableAndAlignsTheVisibleSetAtOnce() async {
        let screen = Size(width: 1_200, height: 720)
        let owner = UUID()
        let (controller, backend) = await laidOutController(
            at: 30,
            surfaceOwner: owner,
            window: screen,
            screen: screen
        )
        let table = controller.layoutTable
        let fullScreen = backend.installed
        let clearCount = backend.clearCount

        resize(controller, owner: owner, window: Size(width: 600, height: 300), screen: screen)
        #expect(controller.layoutTable.mapValues(\.placements) == table.mapValues(\.placements))
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        #expect(backend.installed.count < fullScreen.count)
        #expect(backend.clearCount == clearCount)
        expectVisibility(in: controller, backend, at: 30)

        let (small, _) = await laidOutController(
            at: 30,
            window: Size(width: 600, height: 300),
            screen: screen
        )
        #expect(small.layoutTable.mapValues(\.placements) == table.mapValues(\.placements))

        resize(controller, owner: owner, window: screen, screen: screen)
        #expect(backend.installed == fullScreen)
        #expect(backend.clearCount == clearCount)
    }

    /// 换到尺寸不同的屏幕：按新的规划尺寸整张重排，整屏换成新布局。
    @Test
    func screenChangeRelaysOutTheWholeTable() async {
        let owner = UUID()
        let window = Size(width: 800, height: 360)
        let (controller, backend) = await laidOutController(
            at: 30,
            surfaceOwner: owner,
            window: window,
            screen: window
        )

        resize(controller, owner: owner, window: window, screen: Self.largerScreen)
        await backend.waitUntil {
            !backend.installed.isEmpty
                && backend.installed.values.allSatisfy {
                    $0.planningWidth == Self.largerScreen.width
                }
        }
        #expect(
            controller.layoutTable.values.allSatisfy {
                $0.placements.allSatisfy { $0.planningWidth == Self.largerScreen.width }
            }
        )
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
        expectVisibility(in: controller, backend, at: 30)
    }

    /// 换屏重排用的更大屏幕。
    private static let largerScreen = Size(width: 1_600, height: 900)

    /// 屏上增删的累计记录；暂存期间它不变，说明旧画面一条没动。
    private struct ScreenHistory: Equatable {
        let installed: [String]
        let replaced: [String]
        let removed: [String]

        @MainActor
        init(_ backend: RecordingRenderingBackend) {
            installed = backend.installedHistory
            replaced = backend.replacedHistory
            removed = backend.removedHistory
        }
    }

    /// D 与快照都停在 30、已挂满屏的控制器换到最慢的速度档，返回时整屏暂存正在等延迟的纹理。
    ///
    /// 换档后滚动弹幕走得更久，原本已离场的弹幕此刻仍在屏上，它们要准备纹理，所以暂存一定要等；暂存发起
    /// 时新布局表已经落地。
    private func stagingRelayout(
        owner: UUID
    ) async -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        backend.delaysPreparation = true
        controller.setSpeedLevel(.one)
        await backend.waitUntil { backend.pendingPreparationCount > 0 }
        return (controller, backend)
    }

    /// 完成全部延迟的纹理（完成可能引出新的请求）之后，屏上恰是新布局表在 D 应有的 placement。
    private func drainRelayout(
        _ controller: DanmakuPresentationController,
        _ backend: RecordingRenderingBackend,
        at displayTime: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        while backend.pendingPreparationCount > 0 {
            backend.completePreparations()
        }
        let expected = DanmakuMaterializer.desiredPlacements(
            in: controller.layoutTable,
            at: displayTime,
            viewport: controller.viewport
        )
        let expectedByID = Dictionary(
            uniqueKeysWithValues: expected.map { ($0.request.event.id, $0) }
        )
        #expect(backend.installed == expectedByID, sourceLocation: sourceLocation)
        expectVisibility(in: controller, backend, at: displayTime, sourceLocation: sourceLocation)
    }

    /// 暂停在 `position` 的当前 identity 快照。
    private func pausedSnapshot(at position: Double) -> PlaybackTimelineSnapshot {
        snapshot(identity: identity, position: position, generation: 1, state: .paused)
    }

    /// 时钟层与快照一起到达 `position`：D 先变，快照随后作为检查节拍送达。
    private func move(
        _ controller: DanmakuPresentationController,
        to position: Double,
        generation: UInt64,
        state: PlaybackTimelineState = .playing
    ) {
        clock.time = position
        controller.apply(
            snapshot(identity: identity, position: position, generation: generation, state: state)
        )
    }

    private struct Size {
        let width: Double
        let height: Double
    }

    private func resize(
        _ controller: DanmakuPresentationController,
        owner: UUID,
        window: Size,
        screen: Size
    ) {
        controller.updateSurface(
            width: window.width,
            height: window.height,
            screenWidth: screen.width,
            screenHeight: screen.height,
            backingScale: 2,
            ownerID: owner
        )
    }

    /// 由一个宿主接管的控制器；默认窗口与屏幕都是 800 × 360pt，取景框就是整张规划画布。
    private func makeController(
        owner: UUID = UUID(),
        window: Size = Size(width: 800, height: 360),
        screen: Size = Size(width: 800, height: 360)
    ) -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        controller.attachSurface(ownerID: owner, clock: clock)
        resize(controller, owner: owner, window: window, screen: screen)
        return (controller, backend)
    }

    /// D 与快照都停在 `position`、第一段已布局并挂上屏的控制器。
    private func laidOutController(
        at position: Double,
        surfaceOwner: UUID? = nil,
        window: Size = Size(width: 800, height: 360),
        screen: Size = Size(width: 800, height: 360)
    ) async -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let (controller, backend) = makeController(
            owner: surfaceOwner ?? UUID(),
            window: window,
            screen: screen
        )
        move(controller, to: position, generation: 1, state: .paused)
        controller.setSegments([1: events()], for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        return (controller, backend)
    }

    private func events() -> [DanmakuEvent] {
        (0..<600).map { offset in
            timedEvent(
                id: "event-\(offset)",
                time: Double(offset) * 0.6,
                mode: offset % 4 == 0 ? .top : .scrolling
            )
        }
    }

    private func expectedIDs(
        at position: Double,
        in controller: DanmakuPresentationController
    ) -> Set<String> {
        Set(
            DanmakuMaterializer.desiredPlacements(
                in: controller.layoutTable,
                at: position,
                viewport: controller.viewport
            )
            .map(\.request.event.id)
        )
    }

    private func expectVisibility(
        in controller: DanmakuPresentationController,
        _ backend: RecordingRenderingBackend,
        at displayTime: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        expectVisibilityMatchesTheTable(
            on: backend,
            table: controller.layoutTable,
            viewport: controller.viewport,
            at: displayTime,
            sourceLocation: sourceLocation
        )
    }
}
