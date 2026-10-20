import CoreMedia
import Foundation
import QuartzCore
import Synchronization

/// 弹幕的时钟层：一个普通 `CALayer`，本地时间跟随绑定的播放 item timebase 的媒体时间。
///
/// 时钟层在 timebase 每次速率变化或时间跳变时与它对齐；两次之间按当时的速率外推。timebase 相对宿主时钟
/// 有微小漂移且不为此发通知，长时间不暂停、不 seek 时会累积每小时几十毫秒量级的偏差，下一次变化时消除。
///
/// 拥有时钟层、一个私有串行队列与当前 timebase 的两个通知观察（速率变化、时间跳变）；不拥有 timebase
/// 本身、挂在时钟层下的弹幕 layer（renderer 的 `rootLayer`，由 `DanmakuOverlayView` 挂上与摘下）和
/// 时钟层的几何（同样由 overlay 在主线程布局）。owner 是 `DanmakuOverlayView`。
///
/// 驱动方式：timebase 的通知由播放器的多个内部队列在持有 MediaToolbox 锁的线程上同步发出。回调只向
/// `queue` 投递一次同步，其余都在队列上做：读当前绑定的 timebase 的最新速率与锚点，平移到此刻，用显式
/// `CATransaction` 写时钟层的 `beginTime`／`timeOffset`／`speed`。整个过程不经过主线程，所以主线程被
/// 播放器挡住（暂停时等音频暂停握手、设置 `rate`）时，时钟层照样在 timebase 停下的那一刻停下。
///
/// 线程隔离（`@unchecked Sendable` 的依据）：
/// - 时钟层的 `beginTime`、`timeOffset`、`speed` 只由 `queue` 写（`init` 在对象发布前设初值除外）；
///   时钟层的 frame 与子层增删在主线程。队列上的显式事务提交时，会把主线程在同一 layer 上设了但还没
///   提交的其他属性（例如 frame）一并提交；时钟层不裁剪、不绘制，提前提交 frame 没有可见影响。
/// - 当前 timebase 与观察 token 由 `binding` 这把锁保护；锁内只做赋值与观察的登记注销，不调用 Core Media
///   或 Core Animation。通知回调从不取这把锁，所以锁内注销观察不会与正在发通知、持有播放器锁的线程互相等待。
///
/// 生命周期：`bind` 注销旧 timebase 的观察、登记新 timebase 的观察，然后投递一次主动同步（状态不变时
/// timebase 不发通知）；绑定 nil 时投递的同步把时钟层停在当前本地时间、速率 0。同步总是读执行那一刻
/// 绑定的 timebase，所以旧 timebase 迟到的通知（注销前已发出、或已投递还没执行）最多让当前绑定多同步
/// 一次，结果相同，无害。
final class DanmakuTimebaseClock: @unchecked Sendable {
    /// 媒体时间 0 对应的动画 `beginTime`，由窗口组装注入弹幕 renderer。
    ///
    /// 时钟层的本地时间就是媒体时间，弹幕动画的 `beginTime` 直接写弹幕的时间点；但 Core Animation 把
    /// `beginTime` 0 当作「加入时的当前时间」，所以时间点 0 写成一个可忽略的正数。
    static let beginTimeAtMediaZero: CFTimeInterval = 1e-100

    /// 弹幕的父层，本地时间跟随绑定的 timebase；未绑定时停在速率 0。
    let layer = CALayer()
    private let queue = DispatchQueue(
        label: "BiliKit.DanmakuTimebaseClock",
        qos: .userInteractive
    )
    private let binding = Mutex(Binding())

    /// 当前绑定的 timebase 与它的观察 token。
    private struct Binding {
        var timebase: CMTimebase?
        var observers: [any NSObjectProtocol] = []
    }

    init() {
        // 绑定前停在媒体时间 0；默认速率 1 会让本地时间等于宿主时间，挂上的弹幕位置毫无意义。
        layer.speed = 0
        layer.timeOffset = 0
    }

    /// 注销观察。
    ///
    /// 队列里的 block 强引用本对象，所以 `deinit` 可能在队列线程上、最后一个 block 执行完时发生：block
    /// 形式观察的 `removeObserver` 可以在任何线程调用；时钟层由父层另外持有，这里不碰它。
    deinit {
        let observers = binding.withLock { $0.observers }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// 绑定到 `timebase`（nil 表示解绑）；同一个 timebase 是否重复绑定由调用方判断。
    ///
    /// 由 `DanmakuOverlayView` 在主线程调用，调用方必须先让呈现控制器清屏：时钟层随后立即按新 timebase
    /// 运行，旧弹幕会在新时间线上错位。时钟层的更新是异步的，返回时可能还没落到 layer 上，通常在下一帧前完成。
    func bind(_ timebase: CMTimebase?) {
        binding.withLock { binding in
            for observer in binding.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            binding.timebase = timebase
            binding.observers = timebase.map { observe($0) } ?? []
        }
        scheduleSync()
    }

    /// 登记速率变化与时间跳变通知。
    ///
    /// 通知在发出它的线程上同步执行（queue 传 nil）。
    private func observe(_ timebase: CMTimebase) -> [any NSObjectProtocol] {
        let names = [
            Notification.Name(kCMTimebaseNotification_EffectiveRateChanged as String),
            Notification.Name(kCMTimebaseNotification_TimeJumped as String)
        ]
        return names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: timebase,
                queue: nil
            ) { [weak self] _ in
                // 这里在持有 MediaToolbox 锁的播放器线程上：调用任何 AVPlayer／AVPlayerItem API（例如
                // `currentTime()`）会死锁，任何等待（主线程、锁、同步队列）都会原样延长播放器的持锁时间、
                // 挡住主线程。所以只投递；通知自带的 payload 也不用，多个来源的到达顺序不保证，队列上读最新锚点。
                self?.scheduleSync()
            }
        }
    }

    private func scheduleSync() {
        queue.async { [self] in
            sync()
        }
    }

    /// 只在 `queue` 上执行：把时钟层平移到此刻、当前绑定的 timebase 的状态。
    ///
    /// 读完绑定、写入之前可能又有一次 `bind`，这时写入的是旧 timebase，但新绑定投递的同步排在后面，随即覆盖。
    private func sync() {
        let timebase = binding.withLock { $0.timebase }
        // 时钟层挂在 AppKit 视图的 layer 树下，祖先都没有改时间属性，父层的本地时间就是
        // `CACurrentMediaTime()`；`beginTime` 按父层时间写，所以 `now` 直接取它。
        let now = CACurrentMediaTime()
        let timeOffset: CFTimeInterval
        let speed: Float
        if let timebase {
            // 读不出锚点时沿用上一次的状态，直到下一次通知或绑定再同步：timebase 正常时总能读出，
            // 为这种异常另起重试只会多一个没有 owner 的定时器。
            guard let anchor = Self.hostAnchor(of: timebase) else { return }
            // 锚点是 (宿主时间 Ha, 媒体时间 Ta, 速率)：外推到 now 的媒体时间作为 timeOffset，
            // 本地时间 = (父层时间 − now) × rate + timeOffset，此后由渲染服务器按 rate 插值。
            timeOffset = anchor.mediaTime + (now - anchor.hostTime) * anchor.rate
            speed = Float(anchor.rate)
        } else {
            // 解绑：停在此刻的本地时间。只有本队列写这三个属性，读到的是一致的一组；重复执行结果不变。
            timeOffset = (now - layer.beginTime) * Double(layer.speed) + layer.timeOffset
            speed = 0
        }
        // 队列线程没有 runloop，隐式事务不会提交，必须显式提交。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.beginTime = now
        layer.timeOffset = timeOffset
        layer.speed = speed
        CATransaction.commit()
    }

    /// timebase 相对宿主时钟的速率与锚点。
    ///
    /// 宿主时钟与 `CACurrentMediaTime()` 同为 mach 时间的秒数。读不出或不是有限值时返回 nil。
    private static func hostAnchor(
        of timebase: CMTimebase
    ) -> (rate: Double, mediaTime: Double, hostTime: Double)? {
        var rate: Float64 = 0
        var mediaTime = CMTime.invalid
        var hostTime = CMTime.invalid
        let status = CMSyncGetRelativeRateAndAnchorTime(
            timebase,
            relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate,
            anchorTimeOut: &mediaTime,
            relativeToAnchorTimeOut: &hostTime
        )
        guard
            status == noErr, rate.isFinite,
            mediaTime.isNumeric, hostTime.isNumeric
        else { return nil }
        return (rate, mediaTime.seconds, hostTime.seconds)
    }
}
