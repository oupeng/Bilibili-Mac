import BiliApplication
import BiliModels
import Foundation

public struct DanmakuTextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum DanmakuPreparationRejectionReason: Sendable, Equatable {
    case capacity
    case invalidInput
    case oversized
    case cancelled
}

public enum DanmakuPreparationResult: Sendable, Equatable {
    case ready(DanmakuTextMetrics)
    case rejected(DanmakuPreparationRejectionReason)
}

/// 弹幕运动时长的唯一策略来源；基准速度、长度加成与上下限都是产品固定值。
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
            let rawDuration = (surfaceWidth + textWidth) / mediaPointSpeed
            return min(
                max(rawDuration, minimumScrollingSeconds),
                maximumScrollingSeconds
            )
        }
    }

    /// seek 等不连续之后补位时回看的时长。
    ///
    /// 取顶部／底部弹幕的固定时长，与一条和画面等宽的滚动弹幕跑完全程的时长中的较大者。比画面还宽的
    /// 滚动弹幕补位时缺席，不影响之后的正常投递。
    static func catchUpWindow(
        surfaceWidth: Double,
        speedLevel: DanmakuSpeedLevel
    ) -> Double {
        let scrolling = duration(
            for: .scrolling,
            textWidth: surfaceWidth,
            surfaceWidth: surfaceWidth,
            speedLevel: speedLevel
        )
        return scrolling.isFinite ? max(scrolling, fixedSeconds) : fixedSeconds
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

@MainActor
public protocol DanmakuRenderingBackendDelegate: AnyObject {
    func rendererDidFinish(eventID: String)
}

@MainActor
/// Renderer 的最小平台 port。
///
/// `clearAll` 只移除活动对象；`stop` 还把播放速率归零。尺寸变化只更新 surface geometry；
/// 已有对象保持自己的运动快照，新对象使用新尺寸。
public protocol DanmakuRenderingBackend: AnyObject {
    var delegate: (any DanmakuRenderingBackendDelegate)? { get set }

    /// 准备完成回调必须返回 MainActor；controller 只会在 `.ready` 后执行 lane 准入。
    func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    )

    /// `elapsedSeconds` 是这条弹幕进场后已经走过的媒体时长；补位时大于 0，从对应位置开始运动。
    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        elapsedSeconds: Double
    ) -> Bool
    func discardPreparation(preparationID: UInt64)
    func cancelPendingPreparations()
    func remove(eventID: String)
    func clearAll()
    func setPlaybackRate(_ rate: Double)
    func setOpacity(_ opacity: DanmakuOpacity)
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    )
    func stop()
}
