import AVFoundation
import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import BiliDanmaku

/// 固定 Core Animation renderer 的契约：弹幕动画按媒体时间开始、模型值不可见，位置只由同步父层给出的
/// 媒体时间决定；纹理准备有界、内存压力与无效文本失败关闭；用户透明度在根层，改动不带隐式过渡。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoreAnimationDanmakuRendererTests {
    @Test
    func rendererAppliesUserOpacityAtRootAndReleasesTextureBytes() async throws {
        let renderer = makeRenderer()
        let fixture = fixtureEvent(
            id: "one-layer",
            mode: .scrolling,
            colorRGB: 0xD0E0F0
        )
        _ = try await prepareAndInstall(
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
        #expect(owner.consume(preparationID: 1, expectedKey: key) != nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 2) == ready)
        #expect(counter.count == 1)

        owner.handleMemoryPressure()
        #expect(owner.outstandingRequestCount == 0)
        #expect(owner.consume(preparationID: 2, expectedKey: key) == nil)
        #expect(await prepare(owner: owner, event: fixture, preparationID: 3) == ready)
        #expect(counter.count == 2)
    }

    /// 内存压力只拒绝当时在途的准备；之后重新准备同一事件仍能上屏。
    @Test
    func memoryPressureRejectsInflightPreparationWithoutBlockingLaterRender() async throws {
        let renderer = makeRenderer()
        let fixture = fixtureEvent(id: "pressure", mode: .scrolling)

        let rejected = await withCheckedContinuation { continuation in
            renderer.prepare(
                fixture,
                preparationID: 1
            ) { result in
                continuation.resume(returning: result)
            }
            // 栅格化结果要回到 MainActor 才能完成，这里同步处理内存压力，请求一定仍在途。
            renderer.handleMemoryPressure()
        }
        #expect(rejected == .rejected(.capacity))

        _ = try await prepareAndInstall(
            renderer: renderer,
            event: fixture,
            preparationID: 2,
            originY: 20
        )
        #expect(renderer.rootLayer.sublayers?.count == 1)
    }

    /// 拖动时作废的准备：排队中的栅格化随之取消，不执行，新的准备不排在它们后面。
    @Test
    func discardedQueuedPreparationsAreNeverRasterized() async {
        let gate = RasterizationGate()
        let owner = DanmakuTexturePreparationOwner(
            configuration: .init(
                maximumConcurrentOperations: 1,
                maximumOutstandingRequests: 16,
                cacheLimits: .production
            ),
            rasterize: { gate.rasterize($0) }
        )
        func prepare(_ text: String, id: UInt64) {
            owner.prepare(
                event: textEvent(text),
                backingScale: 2,
                preparationID: id
            ) { _ in }
        }

        // 第一个栅格化占住唯一的并发名额，后面两个在队列里排着。
        prepare("busy", id: 1)
        await gate.waitUntilBlocked()
        prepare("stale-a", id: 2)
        prepare("stale-b", id: 3)
        owner.discard(preparationID: 2)
        owner.discard(preparationID: 3)

        let fresh = await withCheckedContinuation { continuation in
            owner.prepare(
                event: textEvent("fresh"),
                backingScale: 2,
                preparationID: 4
            ) { result in
                continuation.resume(returning: result)
            }
            gate.release()
        }

        #expect(fresh == .ready(DanmakuTextMetrics(width: 16, height: 1)))
        #expect(gate.rasterizedTexts == ["busy", "fresh"])
    }

    private func textEvent(_ text: String) -> DanmakuEvent {
        DanmakuEvent(
            id: text,
            timeSeconds: 1,
            mode: .scrolling,
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
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
            preparationID: 1
        ) { _ in }
        owner.prepare(
            event: fixtureEvent(id: "bounded-second", mode: .scrolling),
            backingScale: 2,
            preparationID: 2
        ) { result in
            secondResult = result
        }

        #expect(secondResult == .rejected(.capacity))
        #expect(owner.outstandingRequestCount == 1)
        owner.cancelAllPreparations()
        #expect(owner.outstandingRequestCount == 0)
    }

    @Test
    func stoppedPreparationOwnerAndRendererAreReleased() async throws {
        weak var weakRenderer: CoreAnimationDanmakuRenderer?
        do {
            let renderer = makeRenderer()
            weakRenderer = renderer
            _ = try await prepareAndInstall(
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
        let renderer = makeRenderer()
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

    /// 动画在弹幕自己的媒体时间开始（时间点 0 换成同步 layer 约定的常量），结束后不移除；
    /// 模型值不可见：滚动弹幕停在画面左外侧，顶部底部弹幕不透明度为 0。
    @Test
    func animationsStartAtTheEventsMediaTimeAndLeaveInvisibleModelValues() async throws {
        let renderer = makeRenderer()
        _ = try await prepareAndInstall(
            renderer: renderer,
            event: fixtureEvent(id: "scroll-zero", mode: .scrolling),
            preparationID: 1,
            originY: 20,
            admittedAt: 0
        )
        let scrollingLayer = try #require(renderer.rootLayer.sublayers?.last)
        _ = try await prepareAndInstall(
            renderer: renderer,
            event: fixtureEvent(id: "top-later", mode: .top),
            preparationID: 2,
            originY: 60,
            admittedAt: 12.5
        )
        let topLayer = try #require(renderer.rootLayer.sublayers?.last)
        let scrollingAnimation = try #require(
            scrollingLayer.animation(forKey: CoreAnimationDanmakuRenderer.animationKey)
                as? CABasicAnimation
        )
        let topAnimation = try #require(
            topLayer.animation(forKey: CoreAnimationDanmakuRenderer.animationKey)
                as? CABasicAnimation
        )

        #expect(scrollingAnimation.beginTime == AVCoreAnimationBeginTimeAtZero)
        #expect(topAnimation.beginTime == 12.5)
        #expect(!scrollingAnimation.isRemovedOnCompletion)
        #expect(!topAnimation.isRemovedOnCompletion)
        #expect(scrollingAnimation.duration == 4)
        #expect(scrollingLayer.position.x == -scrollingLayer.bounds.width / 2)
        #expect(scrollingLayer.opacity == 1)
        #expect(topLayer.opacity == 0)
        #expect(topAnimation.keyPath == "opacity")
        #expect(topAnimation.fromValue as? Double == 1)
    }

    /// 在模拟同步 layer 的父层下，弹幕 layer 的局部时间就是父层给出的媒体时间。
    ///
    /// 暂停时冻结、seek 时跳到新时间、倍速时按倍率推进。renderer 不改 `rootLayer` 的时间属性，动画开始于
    /// 弹幕的媒体时间，所以位置只取决于父层给出的媒体时间；插值本身由 Core Animation 完成，这里不重算。
    @Test
    func layerTimeFollowsTheSynchronizedParentsMediaTime() async throws {
        let renderer = makeRenderer()
        let clock = CALayer()
        clock.addSublayer(renderer.rootLayer)
        let metrics = try await prepareAndInstall(
            renderer: renderer,
            event: fixtureEvent(id: "media-time", mode: .scrolling),
            preparationID: 1,
            originY: 20,
            admittedAt: 10
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)
        let animation = try #require(
            layer.animation(forKey: CoreAnimationDanmakuRenderer.animationKey)
                as? CABasicAnimation
        )
        func localTime(atHostTime hostTime: CFTimeInterval) -> Double {
            layer.convertTime(hostTime, from: nil)
        }

        #expect(animation.beginTime == 10)
        #expect(animation.fromValue as? Double == 800 + metrics.width / 2)
        #expect(animation.toValue as? Double == -metrics.width / 2)
        #expect(abs(layer.position.x + metrics.width / 2) < 0.001)
        #expect(renderer.rootLayer.speed == 1)
        #expect(renderer.rootLayer.timeOffset == 0)

        // 暂停在 11 秒：局部时间冻结在 11。
        let now = CACurrentMediaTime()
        clock.speed = 0
        clock.timeOffset = 11
        #expect(abs(localTime(atHostTime: now) - 11) < 0.001)
        #expect(abs(localTime(atHostTime: now + 30) - 11) < 0.001)

        // 暂停中 seek 到 13 秒：立即是 13。
        clock.timeOffset = 13
        #expect(abs(localTime(atHostTime: now) - 13) < 0.001)

        // 以 2 倍速从 12 秒起播：半秒主机时间推进一秒媒体时间。
        clock.beginTime = now
        clock.timeOffset = 12
        clock.speed = 2
        #expect(abs(localTime(atHostTime: now + 0.5) - 13) < 0.001)
    }

    /// 重新布局后就地换成新的车道，复用纹理，不重新准备。
    @Test
    func updateMovesAnInstalledLayerToItsNewPlacement() async throws {
        let renderer = makeRenderer()
        let event = fixtureEvent(id: "relayout", mode: .scrolling)
        let metrics = try await prepareAndInstall(
            renderer: renderer,
            event: event,
            preparationID: 1,
            originY: 20,
            admittedAt: 3
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)
        let contents = layer.contents as AnyObject?
        let moved = placement(event: event, metrics: metrics, originY: 80, admittedAt: 3)
        let absent = placement(
            event: fixtureEvent(id: "absent", mode: .top),
            metrics: metrics,
            originY: 0,
            admittedAt: 0
        )

        #expect(renderer.update(moved))
        #expect(renderer.rootLayer.sublayers?.count == 1)
        #expect(renderer.rootLayer.sublayers?.first === layer)
        #expect(layer.contents as AnyObject? === contents)
        #expect(abs(layer.position.y - (80 + metrics.height / 2)) < 0.001)
        #expect(!renderer.update(absent))
    }

    /// 纹理字节超限时：前瞻弹幕不能再挂上，也不挤掉别人；已进场的弹幕挤掉进场最晚的前瞻弹幕后挂上。
    @Test
    func textureBudgetFavoursEnteredDanmakuOverLookahead() async throws {
        let renderer = makeRenderer()
        let text = String(repeating: "W", count: 100)
        var nextPreparationID: UInt64 = 0
        func install(_ id: String, admittedAt: Double) async -> DanmakuInstallResult {
            let event = DanmakuEvent(
                id: id,
                timeSeconds: admittedAt,
                mode: .scrolling,
                text: text,
                fontSize: 36,
                colorRGB: 0xFFFFFF,
                colorStyle: .solid,
                weight: 1
            )
            nextPreparationID += 1
            guard
                case .ready(let metrics) = await prepare(
                    renderer: renderer,
                    event: event,
                    preparationID: nextPreparationID
                )
            else {
                return .notInstalled
            }
            return renderer.install(
                placement(event: event, metrics: metrics, originY: 0, admittedAt: admittedAt),
                preparationID: nextPreparationID,
                at: 5
            )
        }

        var lookaheadIDs: [String] = []
        while lookaheadIDs.count < 200 {
            let id = String(format: "lookahead-%03d", lookaheadIDs.count)
            let result = await install(id, admittedAt: 6)
            #expect(result.evictedEventIDs.isEmpty)
            guard result.isInstalled else { break }
            lookaheadIDs.append(id)
        }
        #expect(!lookaheadIDs.isEmpty && lookaheadIDs.count < 200)
        let installedBefore = renderer.rootLayer.sublayers?.count

        let entered = await install("entered", admittedAt: 4)
        #expect(entered.isInstalled)
        #expect(entered.evictedEventIDs == [try #require(lookaheadIDs.last)])
        #expect(renderer.rootLayer.sublayers?.count == installedBefore)
        #expect(
            renderer.activeTextureByteCost
                <= CoreAnimationDanmakuRenderer.maximumActiveTextureByteCost
        )
    }

    /// 上屏、移除、子层与几何变化不带隐式过渡：弹幕 layer 与 rootLayer 都禁用这些动作。
    @Test
    func renderedLayersAndRootDisableImplicitOrderingActions() async throws {
        let renderer = makeRenderer()
        _ = try await prepareAndInstall(
            renderer: renderer,
            event: fixtureEvent(id: "no-fade", mode: .top),
            preparationID: 1,
            originY: 20
        )
        let layer = try #require(renderer.rootLayer.sublayers?.first)

        for key in [
            "onOrderIn", "onOrderOut", "sublayers", "position", "bounds", "opacity"
        ] {
            #expect(layer.actions?[key] is NSNull)
            #expect(renderer.rootLayer.actions?[key] is NSNull)
        }
    }

    private func makeRenderer() -> CoreAnimationDanmakuRenderer {
        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtZero: AVCoreAnimationBeginTimeAtZero,
            crossfadeClock: ContinuousClock()
        )
        renderer.updateSurfaceSize(width: 800, height: 240, backingScale: 2)
        return renderer
    }

    private func prepareAndInstall(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64,
        originY: Double,
        admittedAt: Double = 1
    ) async throws -> DanmakuTextMetrics {
        let result = await prepare(
            renderer: renderer,
            event: event,
            preparationID: preparationID
        )
        guard case .ready(let metrics) = result else {
            Issue.record("texture preparation was rejected")
            return DanmakuTextMetrics(width: 0, height: 0)
        }
        let installation = renderer.install(
            placement(event: event, metrics: metrics, originY: originY, admittedAt: admittedAt),
            preparationID: preparationID,
            at: admittedAt
        )
        #expect(installation.isInstalled)
        return metrics
    }

    private func prepare(
        renderer: CoreAnimationDanmakuRenderer,
        event: DanmakuEvent,
        preparationID: UInt64
    ) async -> DanmakuPreparationResult {
        await withCheckedContinuation { continuation in
            renderer.prepare(
                event,
                preparationID: preparationID
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
                preparationID: preparationID
            ) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func placement(
        event: DanmakuEvent,
        metrics: DanmakuTextMetrics,
        originY: Double,
        admittedAt: Double
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
            admittedAtSeconds: admittedAt,
            expiresAtSeconds: admittedAt + 4
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

/// 第一次栅格化阻塞到测试放行，用来占住准备队列；记录实际栅格化过的文字。
private final class RasterizationGate: Sendable {
    private let state = Mutex((texts: [String](), isBlocking: true))
    private let released = DispatchSemaphore(value: 0)
    private let blocked = AsyncStream<Void>.makeStream()

    var rasterizedTexts: [String] { state.withLock { $0.texts } }

    func rasterize(_ key: DanmakuTextureCacheKey) -> DanmakuTexturePayload? {
        let blocks = state.withLock { value -> Bool in
            value.texts.append(key.text)
            defer { value.isBlocking = false }
            return value.isBlocking
        }
        if blocks {
            blocked.continuation.yield()
            released.wait()
        }
        return fixtureTexturePayload(byteCost: 64)
    }

    func waitUntilBlocked() async {
        for await _ in blocked.stream { return }
    }

    func release() {
        released.signal()
    }
}
