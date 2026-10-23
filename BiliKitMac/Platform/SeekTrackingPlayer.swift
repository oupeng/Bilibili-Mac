@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// 窗口播放器上 seek 的快照：当前 item 是否还有没落地的 seek，以及累计有几次 seek 以 `finished == true`
/// 落地。
///
/// `landedSeekCount` 每落地一次加一，落地即新位置的画面已经出来；播放器浮层用它把等画面的计时起点移到最近
/// 一次画面更新（见 `PlayerOverlayModel.setWaitingForPicture`）。
struct PlayerSeekActivity: Equatable, Sendable {
    static let idle = PlayerSeekActivity(hasPendingSeek: false, landedSeekCount: 0)

    let hasPendingSeek: Bool
    let landedSeekCount: UInt64
}

/// 记录在途 seek 的窗口播放器，供播放器浮层判断用户是否还在等新位置的画面。
///
/// AVPlayer 没有公开“正在 seek”的状态，而暂停中 seek、AVKit 原生进度条的点击与拖动（AVKit 先把速率设为 0，
/// 在后台线程调用 seek，落地后才恢复速率）、progressive 源的 seek（期间 `timeControlStatus` 仍是 playing）
/// 这几种情况下 `timeControlStatus` 都不是 waiting，只有 seek 调用本身能说明画面还停在旧位置。所以这里拦截
/// AVPlayer 的四个 `CMTime` seek 入口；三个便捷入口按文档等价转成带容差与回调的完整入口，只有完整入口调用
/// super，同一次 seek 只记一次。`seek(to: Date)` 与 `AVPlayerItem` 上的 seek 不经过这里，本项目与 AVKit
/// 点播都不用它们。
///
/// 每次 seek 发起时登记一个 token，记下当时的 item，完成回调时按 token 注销；只有当前 item 的 token 才算在途。
/// 不能只靠完成回调计数，AVFoundation 的回调实测如下：没有 item 时立即以 false 回调；被新 seek 打断时，
/// 旧 seek 在新 seek 的调用里以 false 回调；换掉 item 后旧 seek 稍后以 true 回调；对已失败的 item seek，
/// 或 seek 到 invalid、indefinite、正负无穷，永远不回调。所以非有限时间不登记（它不会移动画面）；换 item
/// 时清空登记，迟到的旧回调按 token 找不到即忽略，既不注销新 item 的 seek，也不算一次落地。失败的 item
/// 本身不就绪，不会转圈，引擎换掉它时登记随之清空。
///
/// seek 可能在任意线程发起与完成：登记放在 `state` 这把 `Mutex` 里。每次变化后把
/// `activityDidChangeNotification`（object 为本播放器）异步投递到主队列：AVKit 的 seek 线程与 AVPlayer 的
/// seek 实现内部（被打断的回调在那里同步触发）都不等主线程；观察者读取最新快照，按电平而不是按事件处理，
/// 通知晚到或合并都不影响结论。不拥有 item 与 seek 的发起方，只由窗口组装创建一份，与 `AVPlayerEngine`
/// 和播放器宿主共用。
final class SeekTrackingPlayer: AVPlayer {
    nonisolated static let activityDidChangeNotification = Notification.Name(
        "BiliKit.SeekTrackingPlayer.activityDidChange"
    )

    /// 在途 seek 的登记：token 到发起时 item 的 identity（没有 item 时为 nil），以及落地次数。
    private struct State {
        var lastToken: UInt64 = 0
        var pending: [UInt64: ObjectIdentifier?] = [:]
        var landedSeekCount: UInt64 = 0
    }

    private let state = Mutex(State())

    nonisolated var seekActivity: PlayerSeekActivity {
        let item = currentItem.map(ObjectIdentifier.init)
        return state.withLock { state in
            PlayerSeekActivity(
                hasPendingSeek: item != nil && state.pending.values.contains(item),
                landedSeekCount: state.landedSeekCount
            )
        }
    }

    override func replaceCurrentItem(with item: AVPlayerItem?) {
        let hadPendingSeek = state.withLock { state in
            defer { state.pending.removeAll() }
            return !state.pending.isEmpty
        }
        super.replaceCurrentItem(with: item)
        if hadPendingSeek {
            publishChange()
        }
    }

    override func seek(
        to time: CMTime,
        toleranceBefore: CMTime,
        toleranceAfter: CMTime,
        completionHandler: @escaping @Sendable (Bool) -> Void
    ) {
        guard time.isNumeric else {
            super.seek(
                to: time,
                toleranceBefore: toleranceBefore,
                toleranceAfter: toleranceAfter,
                completionHandler: completionHandler
            )
            return
        }
        let item = currentItem.map(ObjectIdentifier.init)
        let token = state.withLock { state in
            state.lastToken &+= 1
            state.pending[state.lastToken] = item
            return state.lastToken
        }
        publishChange()
        super.seek(
            to: time,
            toleranceBefore: toleranceBefore,
            toleranceAfter: toleranceAfter
        ) { [weak self] finished in
            self?.finishSeek(token: token, landed: finished)
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

    nonisolated private func finishSeek(token: UInt64, landed: Bool) {
        let changed = state.withLock { state in
            guard state.pending.removeValue(forKey: token) != nil else { return false }
            if landed {
                state.landedSeekCount &+= 1
            }
            return true
        }
        if changed {
            publishChange()
        }
    }

    nonisolated private func publishChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: Self.activityDidChangeNotification,
                object: self
            )
        }
    }
}
