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
/// 弹幕层的局部时间等于播放 item 的时间，暂停中 seek、开播与倍速后都一致；暂停中 seek 之后开播不清屏、
/// 不隐藏。用带音轨的本地媒体，开播与改速率时系统会按音频时钟重新锚定 timebase。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct DanmakuSynchronizedPlaybackTests {
    /// 局部时间与 item 时间的容差（秒）：两者在不同时刻读取，播放中相差约一次读取的间隔。
    private static let timeTolerance = 0.05

    @Test
    func danmakuTimeFollowsTheItemThroughPausedSeekPlayAndRateChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("danmaku-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = try Self.writeSilentAudio(seconds: 8, in: directory)

        let renderer = CoreAnimationDanmakuRenderer(
            beginTimeAtZero: AVCoreAnimationBeginTimeAtZero
        )
        let controller = DanmakuPresentationController(
            backend: renderer,
            configuration: .production(surfaceWidth: 0, surfaceHeight: 0)
        )
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
        let sync = view.danmakuOverlay.synchronizedLayer
        #expect(sync.playerItem === item)

        // 暂停中 seek 到 2 秒，弹幕按 2 秒整屏挂上。
        player.pause()
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600))
        let identity = PlaybackItemIdentity(bvid: "sync-fixture", cid: 1)
        controller.apply(snapshot(identity, position: 2, rate: 0, state: .paused, landing: 2))
        controller.setSegments(
            [
                1: [
                    Self.event(id: "scroll", time: 1.5),
                    Self.event(id: "top", time: 1.8, mode: .top)
                ]
            ],
            for: identity
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                (renderer.rootLayer.sublayers?.count ?? 0) == 2
            }
        )
        let layers = renderer.rootLayer.sublayers ?? []
        expectLocalTime(of: renderer.rootLayer, matches: item)

        // 开播：同一组 layer 继续走，不清屏、不隐藏。
        player.play()
        controller.apply(snapshot(identity, position: 2, rate: 1, state: .playing, landing: 2))
        #expect(await waitUntil(timeout: .seconds(5)) { item.currentTime().seconds > 2.4 })
        expectLocalTime(of: renderer.rootLayer, matches: item)
        #expect(!renderer.rootLayer.isHidden)
        #expect(renderer.rootLayer.sublayers?.elementsEqual(layers, by: ===) == true)

        // 两倍速：局部时间按两倍推进。
        player.rate = 2
        let rateChangedAt = item.currentTime().seconds
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                item.currentTime().seconds > rateChangedAt + 0.6
            }
        )
        expectLocalTime(of: renderer.rootLayer, matches: item)
        #expect(!renderer.rootLayer.isHidden)
    }

    private func expectLocalTime(
        of layer: CALayer,
        matches item: AVPlayerItem,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let local = layer.convertTime(CACurrentMediaTime(), from: nil)
        let itemTime = item.currentTime().seconds
        #expect(
            abs(local - itemTime) < Self.timeTolerance,
            "弹幕层局部时间 \(local) 与 item 时间 \(itemTime) 不一致",
            sourceLocation: sourceLocation
        )
    }

    private func snapshot(
        _ identity: PlaybackItemIdentity,
        position: Double,
        rate: Double,
        state: PlaybackTimelineState,
        landing: UInt64
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 8,
            rate: rate,
            state: state,
            discontinuityGeneration: landing,
            landingGeneration: landing
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

    /// 写一段静音的 PCM 音频：有音轨，播放器按音频时钟驱动 timebase。
    private static func writeSilentAudio(seconds: Double, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("silence.caf")
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        return url
    }
}
