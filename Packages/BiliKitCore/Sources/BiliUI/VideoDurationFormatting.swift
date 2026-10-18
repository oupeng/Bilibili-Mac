import Foundation

/// 视频时长文字：不足一小时为“分:秒”，否则为“时:分:秒”。
///
/// 调用方保证时长非负，负数触发 precondition。
public enum VideoDurationFormatting {
    public static func string(
        seconds: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        precondition(seconds >= 0, "Video duration must be nonnegative")

        let pattern: Duration.TimeFormatStyle.Pattern =
            if seconds < 3_600 {
                .minuteSecond(padMinuteToLength: 1)
            } else {
                .hourMinuteSecond(padHourToLength: 1)
            }
        return Duration.seconds(seconds).formatted(
            .time(pattern: pattern).locale(locale)
        )
    }
}
