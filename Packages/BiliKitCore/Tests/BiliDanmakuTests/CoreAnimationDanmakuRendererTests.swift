import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import BiliDanmaku

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoreAnimationDanmakuRendererTests {
    @Test
    func rendererAppliesUserOpacityAtRootAndReleasesTextureBytes() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 240)
        let fixture = fixtureEvent(
            id: "one-layer",
            mode: .scrolling,
            colorRGB: 0xD0E0F0
        )
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 20
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)

        let opacity = try #require(DanmakuOpacity(0.35))
        renderer.setOpacity(opacity)
        #expect(abs(Double(renderer.rootLayer.opacity) - 0.35) < 0.001)
        #expect(layer.opacity == 1)
        #expect(renderer.rootLayer.sublayers?.count == 1)
        #expect(renderer.rootLayer.sublayers?.first === layer)
        #expect(renderer.activeTextureByteCost > 0)
        #expect(
            renderer.activeTextureByteCost
                <= CoreAnimationDanmakuRenderer.maximumActiveTextureByteCost
        )
        renderer.remove(eventID: fixture.id)
        #expect(renderer.activeTextureByteCost == 0)
        #expect(renderer.rootLayer.sublayers?.isEmpty ?? true)
    }

    @Test
    func preparationOwnerReusesCachedTextureUntilMemoryPressure() async throws {
        let counter = RasterizationCounter()
        let owner = DanmakuTexturePreparationOwner(
            rasterize: { counter.rasterize($0) }
        )
        let fixture = fixtureEvent(id: "cache", mode: .top)
        let key = try #require(
            DanmakuTextureRasterizer.key(
                event: fixture,
                backingScale: 2
            )
        )
        let ready = DanmakuPreparationResult.ready(
            DanmakuTextMetrics(width: 16, height: 1)
        )

        #expect(await prepare(owner: owner, event: fixture, preparationID: 1) == ready)
        #expect(owner.consume(preparationID: 1, generation: 0, expectedKey: key) != nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 2) == ready)
        #expect(counter.count == 1)

        owner.handleMemoryPressure()
        #expect(owner.outstandingRequestCount == 0)
        #expect(owner.consume(preparationID: 2, generation: 0, expectedKey: key) == nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 3) == ready)
        #expect(counter.count == 2)
    }

    @Test
    func preparationOwnerRejectsWorkBeyondItsHardOutstandingLimit() {
        let owner = DanmakuTexturePreparationOwner(
            configuration: .init(
                maximumConcurrentOperations: 1,
                maximumOutstandingRequests: 1,
                cacheLimits: .production
            ),
            rasterize: { _ in fixtureTexturePayload(byteCost: 64) }
        )
        var secondResult: DanmakuPreparationResult?
        owner.prepare(
            event: fixtureEvent(id: "bounded-first", mode: .scrolling),
            backingScale: 2,
            preparationID: 1,
            generation: 0
        ) { _ in }
        owner.prepare(
            event: fixtureEvent(id: "bounded-second", mode: .scrolling),
            backingScale: 2,
            preparationID: 2,
            generation: 0
        ) { result in
            secondResult = result
        }

        #expect(secondResult == .rejected(.capacity))
        #expect(owner.outstandingRequestCount == 1)
        owner.cancelAllPreparations()
        #expect(owner.outstandingRequestCount == 0)
    }

    @Test
    func staleAnimationCompletionCannotRemoveReplacement() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        let delegate = RecordingRendererDelegate()
        renderer.delegate = delegate
        renderer.updateSurfaceSize(width: 800, height: 200)
        let fixture = fixtureEvent(id: "reused", mode: .top)
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 10
        )
        let oldRelay = try completionRelay(in: renderer)

        renderer.clearAll()
        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 2,
            generation: 1,
            originY: 10
        )
        let replacement = try #require(renderer.rootLayer.sublayers?.first)
        let newRelay = try completionRelay(in: renderer)

        // 按各自动画回调携带的身份完成；旧回调晚到也不能移除同一事件 ID 的新 layer。
        complete(oldRelay, in: renderer)
        #expect(renderer.rootLayer.sublayers?.count == 1)
        #expect(renderer.rootLayer.sublayers?.first === replacement)
        #expect(delegate.finishedEventIDs.isEmpty)

        complete(newRelay, in: renderer)
        #expect(renderer.rootLayer.sublayers?.isEmpty ?? true)
        #expect(delegate.finishedEventIDs == [fixture.id])
    }

    /// 取出唯一活动 layer 上动画的完成回调；它携带渲染时记下的事件 ID、对象身份与 epoch。
    private func completionRelay(
        in renderer: CoreAnimationDanmakuRenderer
    ) throws -> AnimationCompletionRelay {
        let layers = try #require(renderer.rootLayer.sublayers)
        try #require(layers.count == 1)
        let animation = try #require(layers[0].animation(forKey: "danmaku"))
        return try #require(animation.delegate as? AnimationCompletionRelay)
    }

    /// 与 `AnimationCompletionRelay.animationDidStop` 转交的调用相同，只是同步执行以便逐步断言。
    private func complete(
        _ relay: AnimationCompletionRelay,
        in renderer: CoreAnimationDanmakuRenderer
    ) {
        renderer.completeAnimation(
            eventID: relay.eventID,
            objectIdentity: relay.objectIdentity,
            renderEpoch: relay.renderEpoch
        )
    }

    @Test
    func stoppedPreparationOwnerAndRendererAreReleased() async throws {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        do {
            let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
            weakRenderer = renderer
            renderer.updateSurfaceSize(width: 800, height: 300)
            _ = try await prepareAndRender(
                renderer: renderer,
                event: fixtureEvent(id: "release", mode: .scrolling),
                preparationID: 1,
                originY: 20
            )
            renderer.stop()
        }
        #expect(weakRenderer == nil)
    }

    @Test
    func invalidAndOversizedTextFailClosedBeforeLaneAdmission() async {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 300)
        let invalid = DanmakuEvent(
            id: "invalid",
            timeSeconds: 1,
            mode: .scrolling,
            text: "invalid",
            fontSize: .nan,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
        let oversized = DanmakuEvent(
            id: "oversized",
            timeSeconds: 1,
            mode: .scrolling,
            text: String(repeating: "W", count: 512),
            fontSize: 36,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )

        #expect(
            await prepare(
                renderer: renderer,
                event: invalid,
                preparationID: 1
            ) == .rejected(.invalidInput)
        )
        #expect(
            await prepare(
                renderer: renderer,
                event: oversized,
                preparationID: 2
            ) == .rejected(.oversized)
        )
        #expect(renderer.rootLayer.sublayers?.isEmpty ?? true)

        // 拒绝的准备不占用 preparation owner 的有界名额。
        let owner = DanmakuTexturePreparationOwner()
        #expect(
            await prepare(owner: owner, event: invalid, preparationID: 1)
                == .rejected(.invalidInput)
        )
        #expect(
            await prepare(owner: owner, event: oversized, preparationID: 2)
                == .rejected(.oversized)
        )
        #expect(owner.outstandingRequestCount == 0)
    }

    /// 补位弹幕的动画开始时间移到过去，从已经走过的位置继续，而不是从右边缘重新进场。
    @Test
    func catchUpRenderStartsTheAnimationPartWay() async throws {
        let renderer = CoreAnimationDanmakuRenderer(contentsScale: 2)
        renderer.updateSurfaceSize(width: 800, height: 240)
        let fixture = fixtureEvent(id: "catch-up", mode: .scrolling)

        _ = try await prepareAndRender(
            renderer: renderer,
            event: fixture,
            preparationID: 1,
            originY: 20,
            elapsedSeconds: 2
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)
        let animation = try #require(layer.animation(forKey: "danmaku"))
        let localNow = layer.convertTime(CACurrentMediaTime(), from: nil)

        #expect(animation.beginTime < localNow - 1.5)
        #expect(animation.beginTime > localNow - 2.5)
        #expect(animation.duration == 4)
    }

    private func prepareAndRender(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0,
        originY: Double,
        elapsedSeconds: Double = 0
    ) async throws -> DanmakuTextMetrics {
        let result = await prepare(
            renderer: renderer,
            event: event,
            preparationID: preparationID,
            generation: generation
        )
        guard case .ready(let metrics) = result else {
            Issue.record("texture preparation was rejected")
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        let didRender = renderer.renderPrepared(
            placement(event: event, metrics: metrics, originY: originY),
            preparationID: preparationID,
            generation: generation,
            elapsedSeconds: elapsedSeconds
        )
        #expect(didRender)
        return metrics
    }

    private func prepare(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64 = 0
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            renderer.prepare(
                event,
                preparationID: preparationID,
                generation: generation,
                backingScale: 2
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func prepare(
        owner: DanmakuTexturePreparationOwner,
        event: DanmakuEvent,
        preparationID: UInt64
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            owner.prepare(
                event: event,
                backingScale: 2,
                preparationID: preparationID,
                generation: 0
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func placement(
        event: DanmakuEvent,
        metrics: DanmakuTextMetrics,
        originY: Double
    ) -> DanmakuLanePlacement {
        DanmakuLanePlacement(
            request: DanmakuLaneRequest(
                event: event,
                width: metrics.width,
                height: metrics.height,
                durationSeconds: 4
            ),
            laneIndex: 0,
            originY: originY,
            surfaceWidthAtAdmission: 800,
            admittedAtSeconds: 1,
            expiresAtSeconds: 5
        )
    }
}

private final class RasterizationCounter: Sendable {
    private let value = Mutex(0)

    var count: Int { value.withLock { $0 } }

    func rasterize(_ key: DanmakuTextureCacheKey) -> DanmakuTexturePayload? {
        value.withLock { $0 += 1 }
        return fixtureTexturePayload(byteCost: 64)
    }
}

@MainActor
private final class RecordingRendererDelegate:
    DanmakuRenderingBackendDelegate
{
    private(set) var finishedEventIDs: [String] = []

    func rendererDidFinish(eventID: String) {
        finishedEventIDs.append(eventID)
    }
}
