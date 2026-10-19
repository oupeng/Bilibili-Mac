import BiliApplication
import BiliModels
import Foundation

/// 准备好的弹幕纹理在 point 下的尺寸（含描边与阴影留白），用于车道准入与运动时长。
public struct DanmakuTextMetrics: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// 纹理准备被拒绝的原因。
///
/// `capacity`：未完成请求已满、准备 ID 重复，或被内存压力清掉；`invalidInput`：文本为空或过长、
/// 字号或 backing scale 无效；`oversized`：栅格化失败或纹理超出尺寸与字节上限；`cancelled`：请求的
/// backing scale 与 renderer 当前的不一致。
public enum DanmakuPreparationRejectionReason: Sendable, Equatable {
    case capacity
    case invalidInput
    case oversized
    case cancelled
}

/// 纹理准备的结果：就绪时带纹理尺寸，否则带拒绝原因。
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

/// renderer 回报弹幕动画自然结束的通道，由 `DanmakuPresentationController` 实现以回收车道。
///
/// 只对仍是当前对象的 layer 回调；经 `remove`、`clearAll`、`stop` 移除的不回调，
/// 车道由调用方自己清理。
@MainActor
public protocol DanmakuRenderingBackendDelegate: AnyObject {
    func rendererDidFinish(eventID: String)
}

/// Renderer 的最小平台 port。
///
/// `clearAll` 取消在途准备并移除活动对象；`stop` 还把播放速率归零。尺寸变化只更新 surface
/// geometry：已有滚动弹幕保持入场时的运动，顶部与底部弹幕随新宽度重新居中、底部弹幕随高度变化平移；
/// 新对象使用新尺寸。backing scale 变化会取消在途准备。
@MainActor
public protocol DanmakuRenderingBackend: AnyObject {
    var delegate: (any DanmakuRenderingBackendDelegate)? { get set }

    /// 准备完成回调必须返回 MainActor；controller 只会在 `.ready` 后执行 lane 准入。
    ///
    /// 缓存命中与立即拒绝会在调用内同步回调，调用方必须先登记请求再调用。`generation`
    /// 随准备记录保存，`renderPrepared` 时复核。
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
    ///
    /// 返回 false 表示没有上屏：同一事件 ID 已在屏、活动数或纹理字节超限、画面尺寸为 0、
    /// 准备已失效或被淘汰，或 CGImage 创建失败。返回前 renderer 已消费或丢弃这条准备记录；
    /// 调用方归还车道即可，再调用 `discardPreparation` 也无害。
    @discardableResult
    func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        elapsedSeconds: Double
    ) -> Bool
    /// 丢弃一条没有上屏的准备记录；对未知 ID 是空操作。
    func discardPreparation(preparationID: UInt64)
    /// 取消全部在途与已就绪未上屏的准备，被取消的请求不再回调。
    func cancelPendingPreparations()
    func remove(eventID: String)
    func clearAll()
    /// 立即按此刻切换动画速率，保持局部时间连续。
    func setPlaybackRate(_ rate: Double)
    /// 一整批改动（一次 `apply`、一组补位上屏或一次清屏）结束后调用一次：静止且这批改动了画面时，
    /// 在下一显示帧强制窗口重新合成，暂停时不留残影。
    func recompositeIfStill()
    func setOpacity(_ opacity: DanmakuOpacity)
    func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    )
    func stop()
}
