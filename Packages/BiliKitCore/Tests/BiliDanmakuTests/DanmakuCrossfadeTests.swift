import AVFoundation
import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import BiliDanmaku

/// 固定交叉淡化在 renderer 上的契约：旧组整组移出同步 layer、按开始时的媒体时间与速率继续走；淡入淡出是
/// 显式的不透明度动画，放在同步 layer 之外的普通容器上，按挂钟计时，同步 layer 暂停时照常走完；新组复用
/// 旧组的同一个 CGImage；到点或立即结束后只剩新组。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuCrossfadeTests {
    @Test
    func oldGroupLeavesTheClockAndKeepsMovingAtItsRate() async throws {
        let (renderer, clockLayer, _) = makeRenderer()
        let oldLayer = try await install(renderer, id: "old", admittedAt: 10)

        renderer.beginCrossfade(at: 11, rate: 2)

        let group = try #require(oldLayer.superlayer)
        #expect(group !== renderer.rootLayer)
        #expect(!isDescendant(group, of: clockLayer))
        let now = CACurrentMediaTime()
        #expect(abs(oldLayer.convertTime(now, from: nil) - 11) < 0.01)
        #expect(abs(oldLayer.convertTime(now + 0.5, from: nil) - 12) < 0.01)
        #expect(renderer.rootLayer.sublayers?.isEmpty ?? true)
    }

    @Test
    func fadesAreExplicitWallClockAnimationsOutsideThePausedClock() async throws {
        let (renderer, clockLayer, _) = makeRenderer()
        clockLayer.speed = 0
        clockLayer.timeOffset = 30
        let oldLayer = try await install(renderer, id: "old", admittedAt: 29)
        renderer.beginCrossfade(at: 30, rate: 0)
        _ = try await install(renderer, id: "new", admittedAt: 29, preparationID: 2)

        renderer.startCrossfade()

        let incoming = try #require(clockLayer.superlayer)
        let outgoing = try #require(oldLayer.superlayer?.superlayer)
        for (container, from, to) in [(outgoing, 1.0, 0.0), (incoming, 0.0, 1.0)] {
            let fade = try #require(
                container.animation(forKey: DanmakuCrossfade.animationKey) as? CABasicAnimation
            )
            #expect(fade.keyPath == "opacity")
            #expect(fade.fromValue as? Double == from)
            #expect(fade.toValue as? Double == to)
            #expect(fade.duration == 0.2)
            // 开始时间是容器自己的挂钟时间：同步 layer 暂停也照常推进。
            let now = CACurrentMediaTime()
            #expect(abs(fade.beginTime - container.convertTime(now, from: nil)) < 0.1)
            #expect(
                abs(
                    container.convertTime(now + 0.2, from: nil)
                        - container.convertTime(now, from: nil) - 0.2
                )
                    < 0.001
            )
            #expect(!isDescendant(container, of: clockLayer))
        }
        #expect(clockLayer.convertTime(CACurrentMediaTime() + 1, from: nil) == 30)
    }

    @Test
    func newGroupReusesTheOldTexture() async throws {
        let (renderer, _, _) = makeRenderer()
        let oldLayer = try await install(renderer, id: "same", admittedAt: 5)
        renderer.beginCrossfade(at: 6, rate: 1)

        let newLayer = try await install(renderer, id: "same", admittedAt: 5, preparationID: 2)

        #expect(newLayer !== oldLayer)
        #expect(newLayer.contents as AnyObject === oldLayer.contents as AnyObject)
    }

    @Test
    func theFadeEndsByTheClockOrImmediately() async throws {
        let (renderer, _, clock) = makeRenderer()
        let oldLayer = try await install(renderer, id: "old", admittedAt: 5)
        renderer.beginCrossfade(at: 6, rate: 1)
        let newLayer = try await install(renderer, id: "new", admittedAt: 5, preparationID: 2)
        renderer.startCrossfade()

        while clock.sleeperCount == 0 {
            await Task.yield()
        }
        clock.advance(by: DanmakuCrossfade.duration)
        while oldLayer.superlayer != nil {
            await Task.yield()
        }
        #expect(newLayer.superlayer === renderer.rootLayer)

        let second = try await install(renderer, id: "second", admittedAt: 5, preparationID: 3)
        renderer.beginCrossfade(at: 6, rate: 1)
        renderer.finishCrossfade()
        #expect(second.superlayer == nil)
        #expect(newLayer.superlayer == nil)
    }

    /// 挂上同步 layer 替身（普通 CALayer）的 renderer，与给淡化收尾计时的手动时钟。
    private func makeRenderer() -> (CoreAnimationDanmakuRenderer, CALayer, ManualTestClock) {
        let clock = ManualTestClock()
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtZero: AVCoreAnimationBeginTimeAtZero,
            crossfadeClock: clock
        )
        renderer.updateSurfaceSize(width: 800, height: 240, backingScale: 2)
        let clockLayer = CALayer()
        renderer.mount(clockLayer: clockLayer)
        return (renderer, clockLayer, clock)
    }

    private func install(
        _ renderer: CoreAnimationDanmakuRenderer,
        id: String,
        admittedAt: Double,
        preparationID: UInt64 = 1
    ) async throws -> CALayer {
        let event = fixtureEvent(id: id, mode: .scrolling)
        let result = await withCheckedContinuation { continuation in
            renderer.prepare(event, preparationID: preparationID) { result in
                continuation.resume(returning: result)
            }
        }
        guard case .ready(let metrics) = result else {
            Issue.record("texture preparation was rejected")
            return CALayer()
        }
        let placement = DanmakuLanePlacement(
            request: DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: 8
            ),
            laneIndex: 0,
            originY: 0,
            surfaceWidthAtAdmission: 800,
            admittedAtSeconds: admittedAt,
            expiresAtSeconds: admittedAt + 8
        )
        #expect(
            renderer.install(placement, preparationID: preparationID, at: admittedAt).isInstalled
        )
        return try #require(renderer.rootLayer.sublayers?.last)
    }

    private func isDescendant(_ layer: CALayer, of ancestor: CALayer) -> Bool {
        var current = layer.superlayer
        while let next = current {
            if next === ancestor { return true }
            current = next.superlayer
        }
        return false
    }
}

/// 由测试推进的时钟：`sleep` 挂起到 `advance` 越过截止时间；推进前先等 `sleeperCount` 大于 0，
/// 截止时间按睡眠开始时的 `now` 计算。
final class ManualTestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (left: Instant, right: Instant) -> Bool {
            left.offset < right.offset
        }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [(deadline: Instant, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    /// 正在睡眠、等着被推进的调用数。
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await withCheckedContinuation { continuation in
            let resumesNow = state.withLock { state -> Bool in
                guard state.now < deadline else { return true }
                state.sleepers.append((deadline, continuation))
                return false
            }
            if resumesNow {
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        let ready = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ready = state.sleepers.filter { !(now < $0.deadline) }
            state.sleepers.removeAll { !(now < $0.deadline) }
            return ready
        }
        for sleeper in ready {
            sleeper.continuation.resume()
        }
    }
}
