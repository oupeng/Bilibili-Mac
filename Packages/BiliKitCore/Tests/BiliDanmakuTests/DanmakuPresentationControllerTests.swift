import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定呈现控制器的契约：画面在分段布局完成后按当前时刻整屏出现；拖动期间不清屏、不对齐，落地后按新
/// 时刻整屏对齐（落点分段未到时不留旧画面），原地跳变画面不变；关闭弹幕清屏、打开恢复；设置变化整屏换成
/// 新布局；换视频清屏；换 item 只接受当前 owner，清屏后按原布局表挂回；旧 surface owner 的操作无效。
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
        #expect(backend.isStill)
    }

    /// 拖动期间不清屏也不对齐，屏上的 layer 原样随媒体时间走；落地后整屏换成新时刻应有的。
    @Test
    func draggingKeepsTheLayersAndTheLandingAlignsTheNewTime() async {
        let (controller, backend) = await laidOutController(at: 30)
        let before = backend.installed
        let clearCount = backend.clearCount

        controller.apply(
            snapshot(identity: identity, position: 120, generation: 1, seekPhase: .seeking)
        )
        controller.apply(
            snapshot(identity: identity, position: 200, generation: 1, seekPhase: .seeking)
        )
        #expect(backend.installed == before)

        controller.apply(snapshot(identity: identity, position: 200, generation: 2))
        #expect(backend.installedEventIDs == expectedIDs(at: 200, in: controller))
        #expect(backend.clearCount == clearCount)
    }

    /// 落点分段还没到：落地时按新时刻对齐（旧时刻的弹幕全部移走）后显示，分段到达后整屏挂上。
    @Test
    func farSeekShowsNothingStaleUntilItsSegmentArrives() async {
        let (controller, backend) = await laidOutController(at: 30)

        controller.apply(
            snapshot(identity: identity, position: 1_000, generation: 1, seekPhase: .seeking)
        )
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

    /// 起播前暂停、缓冲恢复时的原地跳变也被当作一次 seek：落地后画面不变、不清屏。
    @Test
    func timeJumpInPlaceKeepsTheScreen() async {
        let (controller, backend) = await laidOutController(at: 30)
        let before = backend.installed
        let clearCount = backend.clearCount

        controller.apply(
            snapshot(identity: identity, position: 30.05, generation: 1, seekPhase: .seeking)
        )
        controller.apply(snapshot(identity: identity, position: 30.05, generation: 2))
        #expect(backend.installed == before)
        #expect(backend.clearCount == clearCount)
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
            at: 30
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

    /// 同一视频换线路或清晰度：换 item 时清屏、保留布局表，下一个 settled 快照（落地代号不变）按原布局表
    /// 在当前时刻整屏挂回。
    @Test
    func playerItemChangeClearsAndTheNextSnapshotRestoresTheSameLayout() async {
        let owner = UUID()
        let (controller, backend) = await laidOutController(at: 30, surfaceOwner: owner)
        let before = backend.installed

        controller.playerItemWillChange(ownerID: owner)
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
        controller.updateSurface(width: 10, height: 10, backingScale: 2, ownerID: first)
        #expect(backend.surfaceSizes.count == sizesBefore)
        #expect(!controller.detachSurface(ownerID: first))
        #expect(controller.detachSurface(ownerID: second))
        #expect(backend.stopCount == 0)
    }

    private func makeController() -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration()
        )
        return (controller, backend)
    }

    /// 暂停在 `position`、第一段已布局并挂上屏的控制器。
    private func laidOutController(
        at position: Double,
        surfaceOwner: UUID? = nil
    ) async -> (DanmakuPresentationController, RecordingRenderingBackend) {
        let (controller, backend) = makeController()
        if let surfaceOwner {
            controller.attachSurface(ownerID: surfaceOwner)
        }
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
            DanmakuMaterializer.desiredPlacements(in: controller.layoutTable, at: position)
                .map(\.request.event.id)
        )
    }
}
