import BiliApplication
import BiliModels

/// 调度会话写入 presentation 的边界，实现是 `DanmakuPresentationController`。
///
/// 会话把每个当前 identity 的时间线快照、已缓存的全部分段与用户设置交给呈现端；呈现端自己决定布局与
/// 画面，会话不知道哪些弹幕在屏上。`stopPresentation` 清屏并丢弃 identity、布局表与时间线状态。
@MainActor
public protocol DanmakuPresentationSink: AnyObject {
    /// 每个快照都要送达：呈现端靠它得知 identity、当前媒体时间、是否静止与 seek 阶段。
    func apply(_ snapshot: PlaybackTimelineSnapshot)
    /// 会话当前缓存的全部分段（按分段号）；分段到达或被淘汰时整份重新给出。identity 与呈现端当前的
    /// 不一致时忽略。
    func setSegments(
        _ segments: [Int: [DanmakuEvent]],
        for identity: PlaybackItemIdentity
    )
    func setEnabled(_ enabled: Bool)
    func setFilter(_ filter: DanmakuFilter)
    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel)
    func setOpacity(_ opacity: DanmakuOpacity)
    func setDisplayArea(_ displayArea: DanmakuDisplayArea)
    func setDensity(_ density: DanmakuDensity)
    func stopPresentation()
}
