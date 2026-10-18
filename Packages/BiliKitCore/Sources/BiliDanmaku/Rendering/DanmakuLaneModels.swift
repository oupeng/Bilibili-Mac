import BiliApplication
import BiliModels
import Foundation

/// 车道分配的几何与容量参数，由 `DanmakuPresentationController` 按画面尺寸、
/// 显示区域与密度重建后交给 `DanmakuLaneAllocator`。
///
/// 只影响之后的准入，已活动的 placement 保留入场时的几何；`isValid` 不成立时 allocator
/// 把全部请求按 `invalidRequest` 拒绝。
public struct DanmakuLaneConfiguration: Sendable, Equatable {
    /// 同时活动弹幕数的硬上限，也约束 renderer 的活动 layer 数、呈现控制器排队的准备数与纹理准备
    /// owner 的未完成请求数。
    ///
    /// 它限定的是 Core Animation 合成与纹理内存的最坏情况：调大让高密度时段同屏更多，
    /// 但合成与内存开销随之上升；调小则高峰期更早以容量不足丢弃。
    public static let hardMaximumActiveCount = 640

    /// 产品默认配置：36pt 车道基元、普通密度的水平间距、不叠放、整个画面都是显示区域。
    ///
    /// 初始尺寸可以为 0，surface 布局后由呈现控制器更新；显示区域与密度由用户偏好经呈现控制器覆盖。
    public static func production(
        surfaceWidth: Double,
        surfaceHeight: Double
    ) -> Self {
        Self(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            laneHeight: 36,
            minimumHorizontalGap: DanmakuDensityAdmissionPolicy(.default).minimumHorizontalGap,
            maximumActiveCount: hardMaximumActiveCount,
            displayAreaFraction: 1
        )
    }

    public let surfaceWidth: Double
    public let surfaceHeight: Double
    /// 车道基元高度（point）；纹理高于它的弹幕占用连续多条车道。
    public let laneHeight: Double
    /// 同一车道前后两条滚动弹幕之间的最小水平间距（point），由密度决定。
    public let minimumHorizontalGap: Double
    /// 活动弹幕数上限，不得超过 `hardMaximumActiveCount`。
    public let maximumActiveCount: Int
    /// 可放弹幕的画面高度比例（0...1），车道数按画面高度乘以它计算；滚动与顶部弹幕从顶边往下排，
    /// 底部弹幕从底边往上排。
    public let displayAreaFraction: Double
    /// 同一车道允许叠放的层数；1 表示不叠放，大于 1 时没有完全空闲的车道才按层叠放。
    public let maximumOverlapDepth: Int

    public init(
        surfaceWidth: Double,
        surfaceHeight: Double,
        laneHeight: Double,
        minimumHorizontalGap: Double,
        maximumActiveCount: Int,
        displayAreaFraction: Double,
        maximumOverlapDepth: Int = 1
    ) {
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.laneHeight = laneHeight
        self.minimumHorizontalGap = minimumHorizontalGap
        self.maximumActiveCount = maximumActiveCount
        self.displayAreaFraction = displayAreaFraction
        self.maximumOverlapDepth = maximumOverlapDepth
    }

    var isValid: Bool {
        let values = [
            surfaceWidth,
            surfaceHeight,
            laneHeight,
            minimumHorizontalGap,
            displayAreaFraction
        ]
        guard values.allSatisfy(\.isFinite),
            surfaceWidth > 0,
            surfaceHeight > 0,
            laneHeight > 0,
            minimumHorizontalGap >= 0,
            maximumActiveCount > 0,
            maximumActiveCount <= Self.hardMaximumActiveCount,
            maximumOverlapDepth > 0,
            maximumOverlapDepth <= Self.hardMaximumActiveCount
        else {
            return false
        }
        return displayAreaFraction >= 0 && displayAreaFraction <= 1
    }
}

/// 一条已测量的弹幕申请车道时的输入：纹理尺寸（point，含描边与阴影留白）与运动时长（媒体秒）。
public struct DanmakuLaneRequest: Sendable, Equatable {
    public let event: DanmakuEvent
    public let width: Double
    public let height: Double
    public let durationSeconds: Double

    public init(
        event: DanmakuEvent,
        width: Double,
        height: Double,
        durationSeconds: Double
    ) {
        self.event = event
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
    }

    var isValid: Bool {
        width.isFinite
            && width > 0
            && height.isFinite
            && height > 0
            && durationSeconds.isFinite
            && durationSeconds > 0
            && event.timeSeconds.isFinite
    }
}

/// allocator 准入后的车道位置与占用时段，交给 renderer 安装 layer。
///
/// 时间都是媒体时间：`admittedAtSeconds` 是准入时刻（补位时早于当前位置），到 `expiresAtSeconds`
/// 时车道被回收。`originY` 自画面顶边向下计算。`surfaceWidthAtAdmission` 记录入场时的画面宽度，
/// resize 之后判断追尾仍按这条弹幕实际的速度计算。
public struct DanmakuLanePlacement: Sendable, Equatable {
    public let request: DanmakuLaneRequest
    public let laneIndex: Int
    public let originY: Double
    public let surfaceWidthAtAdmission: Double
    public let admittedAtSeconds: Double
    public let expiresAtSeconds: Double
    public let overlapDepth: Int

    public init(
        request: DanmakuLaneRequest,
        laneIndex: Int,
        originY: Double,
        surfaceWidthAtAdmission: Double,
        admittedAtSeconds: Double,
        expiresAtSeconds: Double,
        overlapDepth: Int = 0
    ) {
        self.request = request
        self.laneIndex = laneIndex
        self.originY = originY
        self.surfaceWidthAtAdmission = surfaceWidthAtAdmission
        self.admittedAtSeconds = admittedAtSeconds
        self.expiresAtSeconds = expiresAtSeconds
        self.overlapDepth = overlapDepth
    }
}

/// allocator 拒绝一条请求的原因。
///
/// `capacity`：活动数已达 `maximumActiveCount`；`noLane`：显示区域放不下，或没有可用车道
/// （滚动弹幕在每个可用槽位都会追尾，顶部与底部弹幕的槽位都被占用）；
/// `invalidRequest`：配置或请求无效、同一事件 ID 已在活动中，或准入时间不是有限值。
public enum DanmakuLaneDropReason: Error, Sendable, Equatable {
    case capacity
    case noLane
    case invalidRequest
}

/// 一次 `admit` 的结果：本次到期回收的 placement 与新准入的 placement；没准入的请求直接丢弃，不排队。
///
/// `expired` 已从 allocator 移除，调用方负责移除对应的 layer。
public struct DanmakuLaneAdmission: Sendable, Equatable {
    public let expired: [DanmakuLanePlacement]
    public let admitted: [DanmakuLanePlacement]
}
