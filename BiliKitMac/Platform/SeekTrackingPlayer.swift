@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// 窗口播放器上在途 seek 的快照：还有几次 seek 没有回调，以及累计发起过几次 seek。
///
/// `generation` 在每次发起 seek 时加一，播放器浮层用它区分“同一次 seek 还没落地”与“又发起了新的 seek”
/// （见 `PlayerOverlayModel.setWaitingForPicture`）。
struct PlayerSeekActivity: Equatable, Sendable {
    private(set) var pendingCount = 0
    private(set) var generation: UInt64 = 0

    var hasPendingSeek: Bool { pendingCount > 0 }

    mutating func begin() {
        pendingCount += 1
        generation &+= 1
    }

    mutating func end() {
        pendingCount = max(0, pendingCount - 1)
    }
}

/// 记录在途 seek 的窗口播放器，供播放器浮层判断用户是否还在等新位置的画面。
///
/// AVPlayer 没有公开“正在 seek”的状态，而暂停中 seek、AVKit 原生进度条的点击与拖动（AVKit 先把速率设为 0，
/// 在后台线程调用 seek，落地后才恢复速率）、progressive 源的 seek（期间 `timeControlStatus` 仍是 playing）
/// 这几种情况下 `timeControlStatus` 都不是 waiting，只有 seek 调用本身能说明画面还停在旧位置。所以这里拦截
/// AVPlayer 的 seek 入口：发起时计数与序号加一，完成回调时计数减一。AVFoundation 对每次 seek 都会回调：
/// 被新 seek 打断时以 `finished == false` 立即回调，换掉 item 或没有 item 时也会立即回调，计数不会悬空。
/// 三个便捷入口按文档等价转成带容差与回调的完整入口，只有完整入口调用 super，避免同一次 seek 记两次。
/// 只覆盖 AVPlayer 上的 seek；`AVPlayerItem` 上的 seek 不经过这里，本项目与 AVKit 都不用它。
///
/// seek 可能在任意线程发起与完成：快照放在 `activity` 这把 `Mutex` 里；每次变化在调用线程发出
/// `activityDidChangeNotification`（object 为本播放器），观察者回到主线程后读取最新快照，按电平而不是按事件
/// 处理，中间状态合并也不影响结论。不拥有 item 与 seek 的发起方，只由窗口组装创建一份，与 `AVPlayerEngine`
/// 和播放器宿主共用。
final class SeekTrackingPlayer: AVPlayer {
    nonisolated static let activityDidChangeNotification = Notification.Name(
        "BiliKit.SeekTrackingPlayer.activityDidChange"
    )

    private let activity = Mutex(PlayerSeekActivity())

    nonisolated var seekActivity: PlayerSeekActivity {
        activity.withLock { $0 }
    }

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        updateActivity { $0.begin() }
        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { [weak self] finished in
            self?.updateActivity { $0.end() }
            completionHandler(finished)
        }
    }

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime
    ) {
        seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { _ in }
    }

    /// 文档规定 `seek(to:)` 与两侧容差为 `positiveInfinity` 的完整入口等价。
    override func seek(
        to time: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        seek(
            to: time,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity,
            completionHandler: completionHandler
        )
    }

    override func seek(to time: CMTime) {
        seek(
            to: time,
            toleranceBefore: .positiveInfinity,
            toleranceAfter: .positiveInfinity
        ) { _ in }
    }

    nonisolated private func updateActivity(_ change: (inout PlayerSeekActivity) -> Void) {
        activity.withLock { change(&$0) }
        NotificationCenter.default.post(
            name: Self.activityDidChangeNotification,
            object: self
        )
    }
}
