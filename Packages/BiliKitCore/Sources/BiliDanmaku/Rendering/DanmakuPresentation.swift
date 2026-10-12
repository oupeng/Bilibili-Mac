import BiliApplication
import BiliModels

public struct DanmakuPresentationUpdate: Sendable, Equatable {
    public let snapshot: PlaybackTimelineSnapshot
    public let batch: DanmakuBatch?

    public init(
        snapshot: PlaybackTimelineSnapshot,
        batch: DanmakuBatch?
    ) {
        self.snapshot = snapshot
        self.batch = batch
    }
}

@MainActor
/// 调度会话写入 presentation 的资源生命周期边界。
///
/// `clearPresentation` 只清空当前画面并保留会话 identity；`stopPresentation` 还终止
/// backend 动画时钟并丢弃 identity/discontinuity 状态。
public protocol DanmakuPresentationSink: AnyObject {
    /// 补位回看的时长：按当前画面宽度与弹幕速度，本应仍在屏上的弹幕最早进场于多少秒前。
    var catchUpWindowSeconds: Double { get }
    func apply(_ update: DanmakuPresentationUpdate)
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func setOpacity(_ opacity: DanmakuOpacity)
    func setDisplayArea(_ displayArea: DanmakuDisplayArea)
    func setDensity(_ density: DanmakuDensity)
    func clearPresentation()
    func stopPresentation()
}
