@preconcurrency import AVFoundation

/// 起播判定与 seek 的时间策略。
enum SeekPolicy {
    static let timescale: CMTimeScale = 600
    /// transport 相对跳转允许落在最近的可解码位置。
    static let relativeSeekTolerance = CMTime(seconds: 0.25, preferredTimescale: timescale)
    /// 就绪位置不超过该值视为从头开始，否则按续播报告。
    static let beginningThresholdSeconds = 0.25
    /// “从头播放”的落点不超过该位置才算成功。
    static let restartLandingLimitSeconds = 0.5
    /// 系统 time-jump 或播放位置离某次 seek 落点不超过该值，就算落在这次 seek 的落点上。
    ///
    /// 覆盖相对跳转的落点容差与 seek 收尾、time-jump、周期回调读数时刻的差异。调大会把更远的真实跳转
    /// 当成同一次 seek 吞掉，调小则同一次 seek 的迟到或重复跳变会被当成新的不连续。
    static let landingMatchToleranceSeconds = 0.5
}

/// `AVPlayerEngine` 一次 seek 等待结束后的结论，决定时间线记为落点、失败还是丢弃。
enum SeekSettlement: Equatable {
    /// 已被更新的 seek、重新 load 或外部时间跳变取代。
    case superseded
    /// AVPlayer 未完成 seek，或落点不满足调用方要求。
    case failed
    /// 等待期间 load、intent、identity 或用户交互已变化。
    case contextChanged
    case landed(positionSeconds: Double)
}
