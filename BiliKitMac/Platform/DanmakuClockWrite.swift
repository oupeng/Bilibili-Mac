import Foundation

/// 时钟层的一次写入：`beginTime`、`timeOffset`、`speed` 三个时间属性，即弹幕时间 D 的一条直线。
///
/// D 只由 `mediaTime(at:)` 一个函数计算：时钟队列算写入前的 D、解绑时冻结、`DanmakuTimebaseClock.displayTime()`
/// 给主线程求 D(now)，都用它；时钟测试不用它，改用 `CALayer.convertTime(_:from:)` 读 Core Animation 自己的换算。
/// `speed` 与 `CALayer.speed` 同为 Float：速率在构造写入之前就取整，主线程求出的直线与 Core Animation 渲染的是
/// 同一条；按 Double 斜率算的话，速率 1.1 时两条直线每小时相差约 0.1ms。
struct DanmakuClockWrite: Equatable, Sendable {
    let beginTime: CFTimeInterval
    let timeOffset: CFTimeInterval
    let speed: Float

    /// 时钟层按这三个属性在父层时间 `hostTime` 的本地时间，即弹幕时间 D。
    ///
    /// `hostTime` 早于 `beginTime` 时停在 `timeOffset`，不外推到写入之前。
    func mediaTime(at hostTime: CFTimeInterval) -> CFTimeInterval {
        timeOffset + max(0, hostTime - beginTime) * Double(speed)
    }
}
