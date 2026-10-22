import CoreMedia
import Foundation
import QuartzCore
import Synchronization

/// 弹幕的时钟层：一个普通 `CALayer`，本地时间跟随绑定的播放 item timebase 的媒体时间。
///
/// 时钟层在 timebase 每次速率变化或时间跳变时与它对齐；两次之间按当时的速率外推。timebase 相对宿主时钟
/// 有微小漂移且不为此发通知，长时间不暂停、不 seek 时会累积每小时几十毫秒量级的偏差，下一次变化时消除。
///
/// 发布：每次写入时钟层之后，把这次写入的直线（`DanmakuClockWrite`）连同绑定纪元发布出去，任意线程经
/// `displayTime()` 用同一个 `DanmakuClockWrite.mediaTime(at:)` 求出此刻的弹幕时间 D，与 Core Animation 渲染的是
/// 同一条线。发布之后向主线程投递一次写入通知（`setWriteHandler`），同一时间最多排一个。
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
/// - 时钟层的 `beginTime`、`timeOffset`、`speed` 与 `written` 只由 `queue` 读写（`init` 在对象发布前设初值
///   除外）；时钟层的 frame 与子层增删在主线程，主线程从不碰这三个时间属性。
/// - 当前 timebase、观察 token、绑定纪元、发布值与写入通知回调由 `binding` 这把锁保护。`binding` 是叶子锁：
///   锁内只做赋值与观察的登记注销，不调用 Core Media 或 Core Animation，不取其他锁。通知回调从不取这把锁，
///   所以锁内注销观察不会与正在发通知、持有播放器锁的线程互相等待。
/// - 三个时间属性的赋值在 Core Animation 的全局锁（`CATransaction.lock()`）内完成，提交在锁外，见
///   `write(_:)`；队列释放这把锁之后才取 `binding` 发布，从不同时持有两把。主线程可能在持有 Core Animation
///   锁时读 `displayTime()`，所以全局只有「Core Animation 锁 → `binding`」一种嵌套，不会死锁。
/// - `writeNotificationPending` 是原子标志，规则见 `notifyWrite()`。
///
/// 生命周期：`bind` 注销旧 timebase 的观察、登记新 timebase 的观察、递增纪元并作废发布值，然后投递一次
/// 主动同步（状态不变时 timebase 不发通知）；绑定 nil 时投递的同步把时钟层停在当前本地时间、速率 0。同步
/// 总是读执行那一刻绑定的 timebase，所以旧 timebase 迟到的通知（注销前已发出、或已投递还没执行）最多让
/// 当前绑定多同步一次，结果相同，无害。
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
    /// 最近一次写到时钟层的直线，只在 `queue` 上读写；初值就是 `init` 给时钟层设的状态。
    ///
    /// 队列算写入前的 D 用它，不回读 layer 的属性。
    private var written = DanmakuClockWrite(beginTime: 0, timeOffset: 0, speed: 0)
    /// 写入通知是否已投递到主线程、还没执行；保证同一时间最多排一个，见 `notifyWrite()`。
    private let writeNotificationPending = Atomic<Bool>(false)

    /// 当前绑定的 timebase、它的观察 token 与发布给其他线程的直线。
    private struct Binding {
        var timebase: CMTimebase?
        var observers: [any NSObjectProtocol] = []
        /// 绑定纪元：只在 `bind` 时递增。
        ///
        /// 队列在同步开头连同 timebase 读出它，发布时纪元已变（期间又换绑）就丢弃这次发布：时钟层已写入的
        /// 旧直线会被 `bind` 投递的下一次同步覆盖，调用方此时已清屏，没有可见后果。
        var epoch: UInt64 = 0
        /// 当前纪元最近一次写入时钟层的直线；从未绑定过、以及 `bind` 之后新纪元第一次写入之前为 nil。
        ///
        /// 从未绑定时时钟层虽然停在媒体时间 0，那只是占位，不代表任何 item 的时间，所以同样读不到 D。
        var published: DanmakuClockWrite?
        /// 写入后在主线程调用的回调，由 owner 设置。
        var writeHandler: (@MainActor @Sendable () -> Void)?
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
    /// 运行，旧弹幕会在新时间线上错位。返回时发布值已作废（`displayTime()` 为 nil），时钟层的更新是异步的，
    /// 新纪元第一次写入通常在下一帧前完成。
    func bind(_ timebase: CMTimebase?) {
        binding.withLock { binding in
            for observer in binding.observers {
                NotificationCenter.default.removeObserver(observer)
            }
            binding.timebase = timebase
            binding.observers = timebase.map { observe($0) } ?? []
            binding.epoch &+= 1
            binding.published = nil
        }
        scheduleSync()
    }

    /// 登记写入通知：每次时钟层写入并发布之后，在主线程调用 `handler`（多次写入可能合并成一次）。
    ///
    /// 由 owner 在主线程设置；`handler` 调用时读 `displayTime()` 拿到的已是触发它的那次写入或更新的发布值。
    func setWriteHandler(_ handler: @escaping @MainActor @Sendable () -> Void) {
        binding.withLock { $0.writeHandler = handler }
    }

    /// 此刻（`CACurrentMediaTime()`）的弹幕时间 D；从未绑定过、或当前纪元还没有写入过时为 nil。
    ///
    /// 任意线程可调用，只取一次 `binding`，不阻塞在队列上。
    func displayTime() -> Double? {
        displayTime(at: CACurrentMediaTime())
    }

    /// 父层时间 `hostTime` 时的弹幕时间 D，按当前发布的直线计算；读不到时为 nil。
    func displayTime(at hostTime: CFTimeInterval) -> Double? {
        binding.withLock { $0.published }?.mediaTime(at: hostTime)
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

    /// 只在 `queue` 上执行：把时钟层平移到此刻、当前绑定的 timebase 的状态，再发布这次写入。
    ///
    /// 读完绑定、写入之前可能又有一次 `bind`，这时写入的是旧 timebase，发布因纪元不符被丢弃，新绑定投递的
    /// 同步排在后面，随即覆盖。
    private func sync() {
        let (timebase, epoch) = binding.withLock { ($0.timebase, $0.epoch) }
        // 时钟层挂在 AppKit 视图的 layer 树下，祖先都没有改时间属性，父层的本地时间就是
        // `CACurrentMediaTime()`；`beginTime` 按父层时间写，所以 `now` 直接取它。
        let now = CACurrentMediaTime()
        let next: DanmakuClockWrite
        if let timebase {
            // 读不出锚点时沿用上一次的状态，直到下一次通知或绑定再同步：timebase 正常时总能读出，
            // 为这种异常另起重试只会多一个没有 owner 的定时器。
            guard let anchor = Self.hostAnchor(of: timebase) else { return }
            // 锚点是 (宿主时间 Ha, 媒体时间 Ta, 速率)：外推到 now 的媒体时间作为 timeOffset，
            // 本地时间 = (父层时间 − now) × speed + timeOffset，此后由渲染服务器按 speed 插值。
            next = DanmakuClockWrite(
                beginTime: now,
                timeOffset: anchor.mediaTime + (now - anchor.hostTime) * anchor.rate,
                speed: Float(anchor.rate)
            )
        } else {
            // 解绑：停在此刻的本地时间；重复执行结果不变。
            next = DanmakuClockWrite(
                beginTime: now,
                timeOffset: written.mediaTime(at: now),
                speed: 0
            )
        }
        write(next)
        publish(next, epoch: epoch)
    }

    /// 只在 `queue` 上执行：把三个时间属性作为一组写到时钟层。
    ///
    /// 队列线程没有 runloop，隐式事务不会提交，必须显式提交。三次赋值放在 `CATransaction.lock()` 里：主线程
    /// 同一轮改过时钟层本身（`layout()` 设 frame、接管 surface 时加子层）时，它的提交会带上这个 layer 当时的
    /// 全部属性，而提交是在同一把锁里收集 layer 状态的；不加锁的话可能把这里写到一半的三元组推上屏，那一帧弹幕在错误的
    /// 时间。提交必须在锁外：提交先取 Core Animation 的 context 锁、再取这把全局锁，持着全局锁提交就与任何
    /// 别的线程的提交（例如 AppKit 在显示链接线程上推进动画）反序加锁，实测会死锁。锁内只有三次赋值，只持
    /// 几微秒，不取 `binding`。反方向的带走仍然存在：这里的提交会把主线程在时钟层上设了但还没提交的 frame
    /// 与子层增删提前带上屏，时钟层不裁剪、不绘制，提前没有可见影响。
    private func write(_ next: DanmakuClockWrite) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.lock()
        layer.beginTime = next.beginTime
        layer.timeOffset = next.timeOffset
        layer.speed = next.speed
        CATransaction.unlock()
        CATransaction.commit()
        written = next
    }

    /// 只在 `queue` 上执行：纪元仍是同步开头读到的 `epoch` 时发布 `next` 并通知主线程。
    ///
    /// 先提交 Core Animation 再发布：主线程按发布值删掉「已走完」的弹幕时，渲染服务器已经在用这条直线。
    private func publish(_ next: DanmakuClockWrite, epoch: UInt64) {
        let isCurrent = binding.withLock { binding in
            guard binding.epoch == epoch else { return false }
            binding.published = next
            return true
        }
        if isCurrent {
            notifyWrite()
        }
    }

    /// 只在 `queue` 上、发布并释放 `binding` 之后执行：向主线程投递一次写入通知，已有一个排着时不再投递。
    ///
    /// 不丢唤醒：主线程先清标志、再取 `binding` 读发布值；队列先在 `binding` 里写发布值、解锁后才置标志。
    /// 置位若看到标志还是 true（不再投递），那个排着的 block 的清位一定在之后，它随后取锁读到的就是这次发布；
    /// 若读发布值挪到锁外，标志也必须挪进锁里。
    private func notifyWrite() {
        guard !writeNotificationPending.exchange(true, ordering: .acquiringAndReleasing) else {
            return
        }
        DispatchQueue.main.async { [self] in
            writeNotificationPending.store(false, ordering: .releasing)
            let handler = binding.withLock { $0.writeHandler }
            MainActor.assumeIsolated {
                handler?()
            }
        }
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
