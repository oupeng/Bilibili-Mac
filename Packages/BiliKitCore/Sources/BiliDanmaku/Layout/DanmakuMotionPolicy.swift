import BiliApplication
import BiliModels
import Foundation

/// 弹幕运动的唯一策略来源：时长、滚动行程与滚动速度；基准速度、长度加成与上下限都是产品固定值。
///
/// 速度只取决于档位与文字宽度、与画面宽度无关，时长 = 行程 / 速度。取景框模型依赖这一点：
/// 滚动弹幕相对右边缘的轨迹与窗口宽度无关，按规划画布排出的表裁成窄窗口，与直接按窄窗口排的运动一致。
/// 上下限在屏幕级画布上不触发（最慢档、短文字要宽过约 5400pt 才碰到 60 秒上限）；改成随画面宽度变化的
/// 速度会破坏取景框，见 docs/ARCHITECTURE.md「弹幕」。
enum DanmakuMotionPolicy {
    static let basePointSpeed = 130.0
    static let lengthReferenceWidth = 960.0
    static let lengthCoefficient = 0.3
    static let minimumScrollingSeconds = 1.5
    static let maximumScrollingSeconds = 60.0
    static let fixedSeconds = 4.0

    static func duration(
        for mode: DanmakuPresentationMode,
        textWidth: Double,
        surfaceWidth: Double,
        speedLevel: DanmakuSpeedLevel
    ) -> Double {
        switch mode {
        case .top, .bottom:
            return fixedSeconds
        case .scrolling:
            guard textWidth.isFinite,
                textWidth > 0,
                surfaceWidth.isFinite,
                surfaceWidth > 0
            else {
                return .nan
            }
            let lengthBonus = lengthCoefficient * textWidth / lengthReferenceWidth
            let mediaPointSpeed =
                basePointSpeed
                * speedMultiplier(for: speedLevel)
                * (1 + lengthBonus)
            let rawDuration =
                scrollingTravel(textWidth: textWidth, planningWidth: surfaceWidth)
                / mediaPointSpeed
            return min(
                max(rawDuration, minimumScrollingSeconds),
                maximumScrollingSeconds
            )
        }
    }

    /// 滚动弹幕一次运动的行程（point）：左缘贴着窗口右边缘入场，到右缘离开规划画布左缘，即规划宽度 +
    /// 文字宽度。
    ///
    /// 时长、车道追尾、取景框的可见时段与渲染动画的终点都由它推出，四处必须是同一个量：任何一处另算，
    /// 屏上的运动就会与准入和可见判断错开。
    static func scrollingTravel(textWidth: Double, planningWidth: Double) -> Double {
        planningWidth + textWidth
    }

    /// 滚动弹幕的匀速（point／媒体秒）：行程除以运动时长。
    ///
    /// 用的是钳制后的时长，所以碰到时长上下限时与 `duration` 里的基准速度不同；屏上实际的速度是这一个。
    static func scrollingSpeed(
        textWidth: Double,
        planningWidth: Double,
        durationSeconds: Double
    ) -> Double {
        scrollingTravel(textWidth: textWidth, planningWidth: planningWidth)
            / durationSeconds
    }

    private static func speedMultiplier(for level: DanmakuSpeedLevel) -> Double {
        switch level {
        case .one: 90 / 130
        case .two: 110 / 130
        case .three: 1
        case .four: 155 / 130
        case .five: 185 / 130
        }
    }
}
