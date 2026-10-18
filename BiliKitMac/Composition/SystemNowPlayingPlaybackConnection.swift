import AVFoundation
import BiliApplication
import BiliPlayback
import Foundation

/// 一次 `defaultRate` KVO 观察的取消句柄，owner 是 `SystemNowPlayingWindowCoordinator`。
///
/// coordinator 的 `close()` 显式取消，未关闭就释放时由 `isolated deinit` 兜底；`cancel()`
/// 之后不会再次执行取消闭包。
@MainActor
final class SystemNowPlayingDefaultRateObservation {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    isolated deinit {
        cancellation?()
    }

    func cancel() {
        cancellation?()
        cancellation = nil
    }
}

/// 窗口 Now Playing 协调器读取播放器状态与执行系统命令的闭包集合，生产实现只由 `live(engine:)`
/// 构造。
///
/// 本身不持有状态，闭包捕获窗口唯一的 `AVPlayerEngine`。`perform` 带着发布时的播放 identity 与
/// `AVPlayerItem` 标识调用，二者与当前播放不一致时返回 false、不动作。
@MainActor
struct SystemNowPlayingPlaybackConnection {
    let currentSnapshot: () -> PlaybackTimelineSnapshot
    let timelineUpdates: () -> AsyncStream<PlaybackTimelineSnapshot>
    let currentItemIdentifier: () -> ObjectIdentifier?
    let currentDefaultPlaybackRate: () -> Double
    let observeDefaultPlaybackRate:
        (@escaping @MainActor @Sendable (Double) -> Void) ->
            SystemNowPlayingDefaultRateObservation
    let perform:
        (
            SystemNowPlayingCommand,
            PlaybackItemIdentity,
            ObjectIdentifier
        ) -> Bool
}

extension SystemNowPlayingPlaybackConnection {
    /// 把系统媒体命令与 `defaultRate` KVO 接到窗口唯一的 `AVPlayerEngine`。
    ///
    /// 每个命令都先复核播放 identity 与 `AVPlayerItem`，旧窗口或旧条目的命令不会作用到新播放。
    static func live(engine: AVPlayerEngine) -> SystemNowPlayingPlaybackConnection {
        SystemNowPlayingPlaybackConnection(
            currentSnapshot: {
                engine.currentTimelineSnapshot
            },
            timelineUpdates: {
                engine.timelineUpdates()
            },
            currentItemIdentifier: {
                engine.player.currentItem.map(ObjectIdentifier.init)
            },
            currentDefaultPlaybackRate: {
                Double(engine.player.defaultRate)
            },
            observeDefaultPlaybackRate: { notify in
                let observation = engine.player.observe(
                    \.defaultRate,
                    options: [.new]
                ) { player, change in
                    let rate = Double(change.newValue ?? player.defaultRate)
                    Task { @MainActor in notify(rate) }
                }
                return SystemNowPlayingDefaultRateObservation {
                    observation.invalidate()
                }
            },
            perform: { command, identity, itemIdentifier in
                guard engine.currentTimelineSnapshot.identity == identity,
                    let item = engine.player.currentItem,
                    ObjectIdentifier(item) == itemIdentifier
                else { return false }
                switch command {
                case .play:
                    engine.play()
                    return true
                case .pause:
                    engine.pause()
                    return true
                case .togglePlayPause:
                    if engine.currentTimelineSnapshot.state == .playing
                        || engine.currentTimelineSnapshot.state == .buffering
                    {
                        engine.pause()
                    } else {
                        engine.play()
                    }
                    return true
                case .seek(let positionSeconds):
                    return requestSystemSeek(
                        positionSeconds,
                        engine: engine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                case .skip(let offsetSeconds):
                    let snapshot = engine.currentTimelineSnapshot
                    guard let duration = snapshot.durationSeconds,
                        let target = SystemNowPlayingSeekTarget.relative(
                            positionSeconds: snapshot.positionSeconds,
                            durationSeconds: duration,
                            offsetSeconds: offsetSeconds
                        )
                    else {
                        return false
                    }
                    return requestSystemSeek(
                        target,
                        engine: engine,
                        identity: identity,
                        itemIdentifier: itemIdentifier
                    )
                }
            }
        )
    }

    private static func requestSystemSeek(
        _ positionSeconds: Double,
        engine: AVPlayerEngine,
        identity: PlaybackItemIdentity,
        itemIdentifier: ObjectIdentifier
    ) -> Bool {
        guard positionSeconds.isFinite, positionSeconds >= 0,
            let duration = engine.currentTimelineSnapshot.durationSeconds,
            positionSeconds <= duration
        else { return false }
        guard engine.currentTimelineSnapshot.identity == identity,
            let item = engine.player.currentItem,
            ObjectIdentifier(item) == itemIdentifier
        else { return false }
        return engine.requestSeek(to: .seconds(positionSeconds))
    }
}

/// 系统“快进／快退”命令的目标位置：当前位置加偏移后夹在 0 与时长之间。
///
/// 位置、时长或偏移不是有限值、时长不为正或偏移为 0 时返回 nil，命令按失败回报。
enum SystemNowPlayingSeekTarget {
    static func relative(
        positionSeconds: Double,
        durationSeconds: Double,
        offsetSeconds: Double
    ) -> Double? {
        guard positionSeconds.isFinite,
            durationSeconds.isFinite,
            durationSeconds > 0,
            offsetSeconds.isFinite,
            offsetSeconds != 0
        else { return nil }
        return min(max(positionSeconds + offsetSeconds, 0), durationSeconds)
    }
}
