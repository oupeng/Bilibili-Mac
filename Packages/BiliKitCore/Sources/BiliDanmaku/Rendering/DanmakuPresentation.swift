import BiliApplication
import BiliModels

/// 会话为每个时间线快照交给呈现端的一次更新：快照本身与调度器给出的可选 batch。
///
/// 没有 batch 时快照仍要送达：呈现端靠它同步暂停、倍速以及 identity 与落地代号的变化。
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

/// 调度会话写入 presentation 的资源生命周期边界。
///
/// `clearPresentation` 只清空当前画面并保留会话 identity；`stopPresentation` 还终止
/// backend 动画时钟并丢弃 identity 与落地代号。
@MainActor
public protocol DanmakuPresentationSink: AnyObject {
    /// 补位回看的时长：按当前画面宽度与弹幕速度，本应仍在屏上的弹幕最早进场于多少秒前。
    ///
    /// 还没有可用的画面尺寸时为 nil：这时补位的弹幕无法准入，调度器保留补位，等窗口可用后再补。
    var catchUpWindowSeconds: Double? { get }
    /// 补位窗口从不可用变为可用时由呈现端在 MainActor 上调用一次；由 `DanmakuSession` 在初始化时设置，
    /// 用于暂停时补上之前因画面尺寸为 0 而没补的弹幕。
    var catchUpWindowAvailabilityHandler: (@MainActor () -> Void)? { get set }
    func apply(_ update: DanmakuPresentationUpdate)
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func setOpacity(_ opacity: DanmakuOpacity)
    func setDisplayArea(_ displayArea: DanmakuDisplayArea)
    func setDensity(_ density: DanmakuDensity)
    func clearPresentation()
    func stopPresentation()
}
