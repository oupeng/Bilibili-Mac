import AVFoundation
import AVKit
import AppKit
import BiliApplication
import BiliDanmaku
import BiliModels
import Testing

@testable import BiliKit

/// 固定弹幕时间来自真实播放器的契约。
///
/// 证明的范围：弹幕 layer 挂在宿主的时钟层下，局部时间等于播放 item 的时间，暂停中 seek、开播、两倍速
/// 与再暂停之后都一致（时钟层在后台队列上异步落地，等到一致为止）；媒体时间
/// 0 的弹幕用时钟定义的哨兵开始，在真实播放下处于可见区间；暂停中 seek 之后开播，屏上仍是同一组
/// layer（呈现控制器没有清屏重建）。
///
/// 依赖：测试宿主能连上窗口服务；用带音轨的本地静音媒体，开播、改速率与暂停时系统会按音频时钟重新锚定
/// timebase，通知来自真实播放器的内部队列。时间线快照是手工喂给控制器的，不经过 `AVPlayerTimelineAdapter`。
///
/// 不能证明：渲染服务器实际画出来的像素与位置、肉眼是否闪烁、真实 B 站 HLS 与码率切换、PiP 与 detached
/// 全屏下的同步。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DanmakuClockPlaybackTests {
    /// 局部时间与 item 时间的容差（秒）：两者在不同时刻读取，播放中相差约一次读取的间隔。
    private static let timeTolerance = 0.05

    @Test
    func danmakuTimeFollowsTheItemThroughPausedSeekPlayRateChangeAndPause() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danmaku-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = try writeSilentAudio(seconds: 8, in: directory)

        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtZero: DanmakuTimebaseClock.beginTimeAtMediaZero
        )
        let controller = DanmakuPresentationController(backend: renderer)
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: nil,
            endMomentaryPlaybackRate: nil
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.danmakuOverlay.detachSurface()
            view.stopObservingPlayerItemChanges()
            view.player = nil
            window.orderOut(nil)
        }
        let item = AVPlayerItem(url: mediaURL)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        view.player = player
        view.startObservingPlayerItemChanges()
        view.layoutSubtreeIfNeeded()
        #expect(await waitUntil(timeout: .seconds(10)) { item.status == .readyToPlay })

        // 暂停中 seek 到 2 秒，弹幕按 2 秒整屏挂上。
        player.pause()
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
        let identity = PlaybackItemIdentity(bvid: "sync-fixture", cid: 1)
        controller.apply(snapshot(identity, position: 2, rate: 0, state: .paused, discontinuity: 2))
        controller.setSegments(
            [
                1: [
                    Self.event(id: "zero", time: 0, mode: .top),
                    Self.event(id: "scroll", time: 1.5),
                    Self.event(id: "top", time: 1.8, mode: .top)
                ]
            ],
            for: identity
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                danmakuLayers(of: renderer).count == 3
            }
        )
        let layers = danmakuLayers(of: renderer)
        await expectLocalTime(of: renderer.rootLayer, matches: item)

        // 媒体时间 0 的弹幕：开始时间是时钟定义的哨兵，此刻（2 秒）仍在它 4 秒的可见区间里。
        let animations = layers.flatMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) }
        }
        let zeroAnimation = try #require(
            animations.first { $0.beginTime == DanmakuTimebaseClock.beginTimeAtMediaZero }
        )
        let zeroLocal = renderer.rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        #expect(zeroLocal >= zeroAnimation.beginTime)
        #expect(zeroLocal < zeroAnimation.beginTime + zeroAnimation.duration)

        // 开播：同一组 layer 继续走，不清屏。
        player.play()
        controller.apply(
            snapshot(identity, position: 2, rate: 1, state: .playing, discontinuity: 2)
        )
        #expect(await waitUntil(timeout: .seconds(5)) { item.currentTime().seconds > 2.4 })
        await expectLocalTime(of: renderer.rootLayer, matches: item)
        #expect(danmakuLayers(of: renderer).elementsEqual(layers, by: ===))

        // 两倍速：局部时间按两倍推进。
        player.rate = 2
        let rateChangedAt = item.currentTime().seconds
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                item.currentTime().seconds > rateChangedAt + 0.6
            }
        )
        await expectLocalTime(of: renderer.rootLayer, matches: item)

        // 暂停：局部时间停在 item 停下的时间，之后不再推进。
        player.pause()
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                let now = CACurrentMediaTime()
                return renderer.rootLayer.convertTime(now + 1, from: nil)
                    == renderer.rootLayer.convertTime(now, from: nil)
            }
        )
        await expectLocalTime(of: renderer.rootLayer, matches: item)
    }

    /// 时钟层由 timebase 通知在后台队列上更新，改变播放状态之后等到局部时间与 item 时间一致。
    private func expectLocalTime(
        of layer: CALayer,
        matches item: AVPlayerItem,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        var local = 0.0
        var itemTime = 0.0
        let matched = await waitUntil(timeout: .seconds(5)) {
            local = layer.convertTime(CACurrentMediaTime(), from: nil)
            itemTime = item.currentTime().seconds
            return abs(local - itemTime) < Self.timeTolerance
        }
        #expect(
            matched,
            "弹幕层局部时间 \(local) 与 item 时间 \(itemTime) 不一致",
            sourceLocation: sourceLocation
        )
    }

    private func snapshot(
        _ identity: PlaybackItemIdentity,
        position: Double,
        rate: Double,
        state: PlaybackTimelineState,
        discontinuity: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 8,
            rate: rate,
            state: state,
            discontinuityGeneration: discontinuity
        )
    }

    private static func event(
        id: String,
        time: Double,
        mode: DanmakuPresentationMode = .scrolling
    ) -> DanmakuEvent {
        DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: mode,
            text: "同步弹幕 sync",
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            weight: 1
        )
    }
}
