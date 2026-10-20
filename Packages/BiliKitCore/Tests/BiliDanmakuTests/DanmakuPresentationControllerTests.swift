import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现控制器的契约：画面在分段布局完成后按当前时刻整屏出现；何时对齐只看位置是否越出上次对齐的
/// 覆盖区间（含回跳），与不连续代号无关，区间长于步长、不超过前瞻，区间内的跳变什么都不做；跳到纹理已
/// 缓存的地方在一次调用里整屏换成那一刻的样子；连续拖动时已就绪的纹理每一步都挂上，拖进未缓存区域、
/// 分段陆续到达时也一样，停下后补齐落点（落点分段未到时不留旧画面）；关闭弹幕清屏、打开恢复；设置变化
/// 整屏换成新布局；换视频清屏；换 item 只接受当前 owner，清屏后直到新 item 的第一个快照才按原布局表
/// 挂回；旧 surface owner 的操作无效；窗口尺寸变化不重排、立即按新取景框增删，屏幕尺寸变化整张重排。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuPresentationControllerTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1Controller", cid: 1)

    @Test
    func screenAppearsOnceTheSegmentIsLaidOut() async {
        let (controller, backend) = makeController()
        controller.apply(snapshot(identity: identity, position: 30, generation: 1, state: .paused))
        controller.setSegments([1: events()], for: identity)

        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
    }

    @Test
    func everyJumpOutOfTheCoveredSpanAlignsTheScreenAtOnce() async {
        let (controller, backend) = await laidOutController(at: 30)
        let clearCount = backend.clearCount

        for position in [120.0, 160, 200] {
            controller.apply(snapshot(identity: identity, position: position, generation: 1))
            #expect(backend.installedEventIDs == expectedIDs(at: position, in: controller))
        }
        #expect(backend.clearCount == clearCount)
    }

    @Test
    func draggingKeepsInstallingReadyTextures() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true

        let steps = Array(stride(from: 120.0, to: 140, by: 1.6))
        for (index, position) in steps.enumerated() {
            controller.apply(snapshot(identity: identity, position: position, generation: 1))
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
    }

    /// 落点分段还没到：按新时刻对齐（旧时刻的弹幕全部移走），分段到达后整屏挂上。
    @Test
    func draggingIntoUncachedSegmentsKeepsFollowing() async {
        let (controller, backend) = await laidOutController(at: 30)
        backend.delaysPreparation = true
        let second = denseEvents(segment: 2, count: 900, seed: 151)
        let third = denseEvents(segment: 3, count: 900, seed: 152)
        func step(to position: Double) {
            controller.apply(snapshot(identity: identity, position: position, generation: 1))
            #expect(!backend.installed.isEmpty)
            #expect(
                backend.installedEventIDs.isSubset(of: expectedIDs(at: position, in: controller))
            )
            backend.completePreparations(backend.pendingPreparationCount / 2)
        }

        for (segments, start) in [
            ([1: events(), 2: second], 400.0), ([1: events(), 2: second, 3: third], 730)
        ] {
            controller.apply(snapshot(identity: identity, position: start, generation: 1))
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
    }

    @Test
    func farSeekShowsNothingStaleUntilItsSegmentArrives() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.apply(
            snapshot(identity: identity, position: 1_000, generation: 2, state: .paused)
        )
        #expect(backend.installed.isEmpty)

        let far = (0..<200).map { timedEvent(id: "far-\($0)", time: 990 + Double($0) * 0.1) }
        controller.setSegments([1: events(), 3: far], for: identity)
        await backend.waitUntil { !backend.installed.isEmpty }
        #expect(backend.installedEventIDs == expectedIDs(at: 1_000, in: controller))
        #expect(backend.installedEventIDs.allSatisfy { $0.hasPrefix("far-") })
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

        controller.apply(snapshot(identity: identity, position: 30.9, generation: 2))
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

        controller.apply(snapshot(identity: identity, position: target, generation: 1))
        #expect(backend.installedEventIDs == expectedIDs(at: target, in: controller))
    }

    @Test
    func disablingClearsAndEnablingRestoresTheCurrentTime() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.setEnabled(false)
        #expect(backend.installed.isEmpty)
        controller.apply(snapshot(identity: identity, position: 45, generation: 1, state: .paused))
        #expect(backend.installed.isEmpty)

        controller.setEnabled(true)
        #expect(backend.installedEventIDs == expectedIDs(at: 45, in: controller))
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

    /// 同一视频换线路或清晰度：换 item 时清屏、保留布局表；新 item 的快照到来之前的 resize 不按旧位置
    /// 挂回，下一个快照按原布局表在当前时刻整屏挂回。
    @Test
    func playerItemChangeClearsAndTheNextSnapshotRestoresTheSameLayout() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        controller.playerItemWillChange(ownerID: owner)
        #expect(backend.installed.isEmpty)
        let window = Size(width: 800, height: 360)
        resize(controller, owner: owner, window: window, screen: window)
        #expect(backend.installed.isEmpty)

        controller.apply(snapshot(identity: identity, position: 30, generation: 1, state: .paused))
        #expect(backend.installed == before)
    }

    @Test
    func staleSurfaceOwnerCannotResizeOrDetach() async {
        let (controller, backend) = makeController()
        let first = UUID()
        let second = UUID()
        controller.attachSurface(ownerID: first)
        controller.attachSurface(ownerID: second)

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

        resize(controller, owner: owner, window: window, screen: Size(width: 1_600, height: 900))
        await backend.waitUntil {
            !backend.installed.isEmpty
                && backend.installed.values.allSatisfy { $0.planningWidth == 1_600 }
        }
        #expect(
            controller.layoutTable.values.allSatisfy {
                $0.placements.allSatisfy { $0.planningWidth == 1_600 }
            }
        )
        #expect(backend.installedEventIDs == expectedIDs(at: 30, in: controller))
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
        controller.attachSurface(ownerID: owner)
        resize(controller, owner: owner, window: window, screen: screen)
        return (controller, backend)
    }

    /// 暂停在 `position`、第一段已布局并挂上屏的控制器。
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
        controller.apply(
            snapshot(identity: identity, position: position, generation: 1, state: .paused)
        )
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
}
