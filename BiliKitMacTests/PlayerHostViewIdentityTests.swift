import AVFoundation
import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Testing

@testable import BiliKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlayerHostViewIdentityTests {
    @Test
    @MainActor
    func nativePlayerViewLeavesNowPlayingOwnershipToProcessController() {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtZero: AVCoreAnimationBeginTimeAtZero)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        #expect(!view.updatesNowPlayingInfoCenter)
    }

    @Test
    @MainActor
    func playbackPreparationBlocksNativePlayerInputAndAccessibility() {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtZero: AVCoreAnimationBeginTimeAtZero)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(true)
        #expect(view.controlsStyle == .none)
        #expect(!view.acceptsFirstResponder)
        #expect(view.hitTest(.zero) == nil)
        #expect(view.isAccessibilityHidden())

        view.setPlaybackPreparationBlocked(false)
        #expect(view.controlsStyle == .default)
        #expect(!view.isAccessibilityHidden())
    }

    @Test
    @MainActor
    func danmakuSurfaceSurvivesTemporaryWindowReparenting() async throws {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtZero: AVCoreAnimationBeginTimeAtZero)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let overlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        overlay.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let firstWindow = NSWindow(
            contentRect: overlay.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 500),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        firstWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer is AVSynchronizedLayer)

        let identity = PlaybackItemIdentity(bvid: "fixture", cid: 1)
        let beforeReparent = danmakuEvent(at: 1, id: "before-reparent", mode: .scrolling)
        controller.apply(pausedSnapshot(identity: identity, position: 1))
        controller.setSegments([1: [beforeReparent]], for: identity)
        #expect(await waitUntil { (renderer.rootLayer.sublayers?.count ?? 0) == 1 })
        let firstLayer = try #require(renderer.rootLayer.sublayers?.first)

        overlay.removeFromSuperview()
        #expect(overlay.window == nil)
        #expect(renderer.rootLayer.superlayer is AVSynchronizedLayer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect((renderer.rootLayer.sublayers?.count ?? 0) == 1)

        overlay.frame = .zero
        overlay.layoutSubtreeIfNeeded()
        controller.setSegments(
            [1: [beforeReparent, danmakuEvent(at: 1.5, id: "during-reparent", mode: .top)]],
            for: identity
        )
        #expect(await waitUntil { (renderer.rootLayer.sublayers?.count ?? 0) == 2 })

        overlay.frame = secondWindow.contentView?.bounds ?? .zero
        secondWindow.contentView?.addSubview(overlay)
        overlay.layoutSubtreeIfNeeded()
        #expect(renderer.rootLayer.superlayer is AVSynchronizedLayer)
        #expect(renderer.rootLayer.sublayers?.first === firstLayer)
        #expect((renderer.rootLayer.sublayers?.count ?? 0) == 2)

        overlay.detachSurface()
        #expect(renderer.rootLayer.superlayer == nil)
        #expect((renderer.rootLayer.sublayers?.count ?? 0) == 0)
    }

    /// 弹幕同步 layer 不会随 `replaceCurrentItem` 自动换绑：宿主在 `currentItem` 变化时先清屏再换绑，
    /// 旧 item 的弹幕不会留在新 item 的时间线上。
    @Test
    @MainActor
    func danmakuClockFollowsTheCurrentItemAndClearsOnReplacement() async throws {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtZero: AVCoreAnimationBeginTimeAtZero)
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: Self.emptyDanmakuConfiguration
        )
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let first = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/first.mp4"))
        let second = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/second.mp4"))
        let player = AVPlayer(playerItem: first)
        view.player = player
        view.startObservingPlayerItemChanges()
        #expect((renderer.rootLayer.superlayer as? AVSynchronizedLayer)?.playerItem === first)

        let identity = PlaybackItemIdentity(bvid: "item-fixture", cid: 1)
        controller.apply(pausedSnapshot(identity: identity, position: 1))
        controller.setSegments(
            [1: [danmakuEvent(at: 1, id: "before-replacement", mode: .top)]],
            for: identity
        )
        #expect(await waitUntil { (renderer.rootLayer.sublayers?.count ?? 0) == 1 })

        player.replaceCurrentItem(with: second)
        #expect(
            await waitUntil {
                (renderer.rootLayer.superlayer as? AVSynchronizedLayer)?.playerItem === second
            }
        )
        #expect(renderer.rootLayer.sublayers?.isEmpty ?? true)
        #expect(renderer.rootLayer.superlayer is AVSynchronizedLayer)
        view.stopObservingPlayerItemChanges()
    }

    private func danmakuEvent(
        at time: Double,
        id: String,
        mode: DanmakuPresentationMode
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "reparent fixture",
            fontSize: 24,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
    }

    private func pausedSnapshot(
        identity: PlaybackItemIdentity,
        position: Double
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 100,
            rate: 0,
            state: .paused,
            discontinuityGeneration: 1,
            landingGeneration: 1
        )
    }

    private static let emptyDanmakuConfiguration = DanmakuLaneConfiguration(
        surfaceWidth: 0,
        surfaceHeight: 0,
        laneHeight: 36,
        minimumHorizontalGap: 12,
        maximumActiveCount: DanmakuLaneConfiguration.hardMaximumActiveCount,
        displayAreaFraction: 1
    )
}
