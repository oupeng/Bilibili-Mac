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

/// Renderer 的最小平台 port，由 `DanmakuMaterializer` 驱动。
///
/// 弹幕 layer 按 placement 的媒体时间运动，port 不涉及时钟：暂停、倍速与 seek 由宿主的同步 layer
/// 处理。`clearAll` 取消在途准备并移除全部 layer；`stop` 还取消显隐与静止重新合成的请求。尺寸变化只
/// 更新 surface geometry：已有滚动弹幕保持布局时的运动，顶部与底部弹幕随新宽度重新居中、底部弹幕随
/// 高度变化平移；backing scale 变化会取消在途准备。
@MainActor
public protocol DanmakuRenderingBackend: AnyObject {
    /// 准备完成回调必须返回 MainActor。
    ///
    /// 缓存命中与立即拒绝会在调用内同步回调，调用方必须先登记请求再调用。`generation`
    /// 随准备记录保存，`install` 时复核。
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

    /// 用已准备好的纹理按 placement 安装一条弹幕；动画在 placement 的媒体时间开始，安装时已过了开始
    /// 时间的直接出现在中途应在的位置。
    ///
    /// 返回 false 表示没有上屏：同一事件 ID 已在屏、纹理字节超限、画面尺寸为 0、准备已失效或被淘汰，
    /// 或 CGImage 创建失败。返回前 renderer 已消费或丢弃这条准备记录。
    @discardableResult
    func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64
    ) -> Bool
    /// 已在屏的弹幕换成新的 placement（重新布局后车道或时长变了），复用原纹理；不在屏时返回 false。
    @discardableResult
    func update(_ placement: DanmakuLanePlacement) -> Bool
    /// 丢弃一条没有上屏的准备记录；对未知 ID 是空操作。
    func discardPreparation(preparationID: UInt64)
    /// 取消全部在途与已就绪未上屏的准备，被取消的请求不再回调。
    func cancelPendingPreparations()
    func remove(eventID: String)
    func clearAll()
    /// 整体隐藏或显示弹幕，不移除 layer；拖动进度条期间用它保持空屏。
    func setHidden(_ hidden: Bool)
    /// 画面是否静止（暂停、缓冲、未播放）；决定 `recompositeIfStill` 是否需要请求下一帧。
    func setStill(_ still: Bool)
    /// 一整批改动（一次 reconcile、一次布局替换或一次清屏）结束后调用一次：静止且这批改动了画面时，
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
