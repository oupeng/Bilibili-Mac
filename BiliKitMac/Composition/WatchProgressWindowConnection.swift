import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import Foundation

/// 窗口观看进度会话的启动、停止与上报权限三个入口，生产实现只由
/// `live(repository:timeline:videoModel:)` 构造。
///
/// 由 `WindowComposition` 持有：窗口 `open()` 时 `start`，`close()` 时 `stop`，关闭后不再启动。
/// `AppRootView` 在 `open()` 之前与每次账户范围变化时调用 `setReportingAccess`，
/// 只有已登录才上报（见 SECURITY-MODEL §3）。
@MainActor
struct WatchProgressWindowConnection {
    let start: () -> Void
    let stop: () -> Void
    let setReportingAccess: (Bool) -> Void
}

extension WatchProgressWindowConnection {
    /// 把窗口的观看进度会话接到共享播放时间线与系统睡眠／唤醒通知。
    static func live(
        repository: any WatchProgressRepository,
        timeline: any PlaybackTimelineProviding,
        videoModel: VideoViewModel
    ) -> WatchProgressWindowConnection {
        let session = WatchProgressSession(
            useCase: WatchProgressUseCase(repository: repository),
            timeline: timeline,
            resolveTarget: { [weak videoModel] identity, loadIntent in
                guard let context = videoModel?.presentedContext else { return nil }
                return WatchProgressTargetResolution.resolve(
                    aid: context.detail.aid,
                    bvid: context.detail.bvid,
                    cid: context.selectedPage.cid,
                    identity: identity,
                    loadIntent: loadIntent
                )
            },
            environment: .live
        )
        let sleepObservation = WatchProgressSleepObservation(
            suspend: { session.suspend() },
            resume: { session.resumeAfterSuspension() }
        )
        return WatchProgressWindowConnection(
            start: {
                session.start()
                sleepObservation.start()
            },
            stop: {
                sleepObservation.stop()
                session.stop()
            },
            setReportingAccess: { session.setReportingAccess(signedIn: $0) }
        )
    }
}

/// 把播放时间线的 identity 解析为观看进度的上报目标。
///
/// 只有视频模型当前呈现的 BV 号与分 P cid 都与时间线 identity 一致、且详情带 aid 时才给出目标；
/// 否则返回 nil，这次不上报，不把进度记到别的视频或分 P 上。
enum WatchProgressTargetResolution {
    static func resolve(
        aid: Int64?,
        bvid: String,
        cid: Int64,
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent
    ) -> WatchProgressTarget? {
        guard bvid == identity.bvid, cid == identity.cid, let aid else {
            return nil
        }
        return WatchProgressTarget(
            aid: aid,
            identity: identity,
            loadIntent: loadIntent
        )
    }
}

/// 系统睡眠与唤醒通知的观察：睡眠时暂停会话计时，唤醒后恢复。
///
/// 由 `WatchProgressWindowConnection.live` 的闭包持有，随窗口连接存活；`start` 先清掉旧观察再登记，
/// `stop` 移除全部观察。通知在主队列投递，回调弱引用自身。
@MainActor
private final class WatchProgressSleepObservation {
    private let suspend: () -> Void
    private let resume: () -> Void
    private var observers = NativeVideoNotificationObservers()

    init(suspend: @escaping () -> Void, resume: @escaping () -> Void) {
        self.suspend = suspend
        self.resume = resume
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.removeAll()
        observers.observe(NSWorkspace.willSleepNotification, object: nil, center: center) {
            [weak self] in self?.suspend()
        }
        observers.observe(NSWorkspace.didWakeNotification, object: nil, center: center) {
            [weak self] in self?.resume()
        }
    }

    func stop() {
        observers.removeAll()
    }
}
