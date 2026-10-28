/// `VideoViewModel.handlePlaybackEnded` 做了什么。
public enum PlaybackEndHandling: Sendable, Equatable {
    /// 不是此刻呈现的那一项、或偏好与访问状态要求停下。
    case none
    /// 已从头重播（单集循环）。
    case replayed
    /// 要重播但引擎没有回到开头：seek 失败、落点不在开头附近，或期间 item、意图或用户操作变了。
    case replayFailed
}
