import Foundation

/// 时钟层的一次写入：`beginTime`、`timeOffset`、`speed` 三个时间属性，即显示时间 D 的一条直线。
///
/// D 只由 `displayTime(at:)` 一个函数计算：时钟队列算写入前的 D、解绑时冻结、`DanmakuTimebaseClock.displayTime()`
/// 给主线程求 D(now)，都用它；时钟测试不用它，改用 `CALayer.convertTime(_:from:)` 读 Core Animation 自己的换算。
/// `speed` 与 `CALayer.speed` 同为 Float：速率在构造写入之前就取整，主线程求出的直线与 Core Animation 渲染的是
/// 同一条；按 Double 斜率算的话，速率 1.1 时两条直线每小时相差约 0.1ms。
struct DanmakuClockWrite: Equatable, Sendable {
    let beginTime: CFTimeInterval
    let timeOffset: CFTimeInterval
    let speed: Float

    /// 时钟层按这三个属性在父层时间 `hostTime` 的本地时间，即显示时间 D。
    ///
    /// `hostTime` 早于 `beginTime` 时停在 `timeOffset`：时钟层的 `fillMode` 是 `.backwards`，Core Animation 在
    /// 开始之前同样冻结在起点（原地等待时 `beginTime` 在未来）。
    func displayTime(at hostTime: CFTimeInterval) -> CFTimeInterval {
        timeOffset + max(0, hostTime - beginTime) * Double(speed)
    }

    /// 在父层时间 `now` 跟上 timebase 的下一次写入：timebase 此刻在 `timebaseTime`、速率 `speed`；`floor` 是
    /// 同一纪元里此刻的显示时间，换绑后的第一次同步传 nil。
    ///
    /// 播放中（`speed` > 0）timebase 此刻低于 `floor` 时不往回跳，原地等待：timebase 的直线
    /// `timebaseTime + (t − now) × speed` 在 `now + (floor − timebaseTime) / speed` 处到达 `floor`，从那一刻起两条
    /// 直线重合，没有残留状态；等待中再同步一次得到同一个写入。首播、seek 后起播与卡顿恢复时系统会把
    /// timebase 后退一个音频输出延迟（macOS 27 实测有线约 −37ms，蓝牙 −97～−215ms），画面停在目标帧上，
    /// 弹幕靠这条规则同样停住。其余情况（速率为 0 时的任何跳变、timebase 不低于 `floor`、没有 `floor`）严格
    /// 跟随：seek、拖动与暂停都发生在速率为 0 时，不需要识别 seek。向前的跳变照样跟随、不做平滑追赶：从暂停
    /// 恢复时前跳约 20～40ms，松开长按倍速时约 100～160ms，画面同样跳。`floor` 为 nil 是为等待补的条件：
    /// 旧时间线上的显示时间对新 item 没有意义，不跟随的话新 item 已在播放时会按旧位置原地等很久。
    static func following(
        timebaseTime: CFTimeInterval,
        speed: Float,
        floor: CFTimeInterval?,
        at now: CFTimeInterval
    ) -> DanmakuClockWrite {
        if speed > 0, let floor, timebaseTime < floor {
            return DanmakuClockWrite(
                beginTime: now + (floor - timebaseTime) / Double(speed),
                timeOffset: floor,
                speed: speed
            )
        }
        return DanmakuClockWrite(beginTime: now, timeOffset: timebaseTime, speed: speed)
    }
}
