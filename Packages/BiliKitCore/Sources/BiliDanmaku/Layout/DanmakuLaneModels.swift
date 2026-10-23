import BiliApplication
import BiliModels
import Foundation

/// 车道分配的几何参数，由 `DanmakuPresentationController` 按规划画布尺寸、显示区域与密度推导
/// （`init(surfaceWidth:surfaceHeight:displayArea:density:)`），经车道布局交给 `DanmakuLaneAllocator`。
///
/// 这里的 surface 是规划画布而不是窗口；窗口只决定露出哪一部分（`DanmakuViewport`）。
///
/// 车道高度与同屏上限是产品常量，不随设置变化。任一参数变化，布局表都按新参数整张重排；`isValid`
/// 不成立时 allocator 拒绝全部请求，画面尚未布局时也就不布局。
struct DanmakuLaneConfiguration: Sendable, Equatable {
    /// 同屏弹幕数的硬上限：车道布局在任一媒体时刻最多准入这么多条，超出的按 (时间, ID) 顺序丢弃；
    /// 也是纹理准备 owner 的未完成请求上限。
    ///
    /// 它限定的是 Core Animation 合成与纹理内存的最坏情况：调大让高密度时段同屏更多，
    /// 但合成与内存开销随之上升；调小则高峰期更早丢弃。
    static let hardMaximumActiveCount = 640

    /// 车道基元高度（point），与最大字号同为 36；更高的纹理占用连续多条车道。
    ///
    /// 调大同屏行数变少，调小则更多弹幕跨多条车道。
    static let laneHeight = 36.0

    /// 车道数的上限，只防止极端画面高度换算成 `Int` 时溢出。
    ///
    /// 8K 竖屏也只有约 120 条车道，这个值远在任何真实画面之上，不影响布局；它与同屏上限无关，
    /// 不复用 `hardMaximumActiveCount`。
    static let maximumLaneCount = 4_096

    let surfaceWidth: Double
    let surfaceHeight: Double
    /// 同一车道前后两条滚动弹幕之间的最小水平间距（point），由密度决定。
    let minimumHorizontalGap: Double
    /// 可放弹幕的画面高度比例（0...1），车道数按画面高度乘以它计算；滚动与顶部弹幕从顶边往下排，
    /// 底部弹幕从底边往上排。
    let displayAreaFraction: Double
    /// 同一车道允许叠放的层数；1 表示不叠放，大于 1 时没有完全空闲的车道才按层叠放。
    let maximumOverlapDepth: Int

    init(
        surfaceWidth: Double,
        surfaceHeight: Double,
        minimumHorizontalGap: Double,
        displayAreaFraction: Double,
        maximumOverlapDepth: Int = 1
    ) {
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.minimumHorizontalGap = minimumHorizontalGap
        self.displayAreaFraction = displayAreaFraction
        self.maximumOverlapDepth = maximumOverlapDepth
    }

    /// 显示区域内的车道数：画面高度乘以比例，按车道高度向下取整，封顶 `maximumLaneCount`。
    ///
    /// 规划画布用它得到布局的车道数，取景框用它得到窗口里可见的车道数；两边必须是同一个计算，车道号
    /// 才能直接比较。
    static func laneCount(surfaceHeight: Double, displayAreaFraction: Double) -> Int {
        let uncapped = floor(surfaceHeight * displayAreaFraction / laneHeight)
        guard uncapped.isFinite, uncapped > 0 else { return 0 }
        return Int(min(uncapped, Double(maximumLaneCount)))
    }

    /// 一条高 `height` 的纹理占用的连续车道数；高度无效或超出车道上限时为 nil。
    static func laneSpan(forHeight height: Double) -> Int? {
        let span = ceil(height / laneHeight)
        guard span.isFinite, span > 0, span <= Double(maximumLaneCount) else { return nil }
        return Int(span)
    }

    /// 叠放层数只来自密度策略，校验上限取策略允许的最大层数。
    var isValid: Bool {
        let values = [surfaceWidth, surfaceHeight, minimumHorizontalGap, displayAreaFraction]
        guard values.allSatisfy(\.isFinite),
            surfaceWidth > 0,
            surfaceHeight > 0,
            minimumHorizontalGap >= 0,
            maximumOverlapDepth > 0,
            maximumOverlapDepth <= DanmakuDensityAdmissionPolicy.overlappingDepth
        else {
            return false
        }
        return displayAreaFraction >= 0 && displayAreaFraction <= 1
    }
}

/// 弹幕密度到车道准入参数的映射：同车道滚动弹幕的最小水平间距（point）与可叠放层数。
///
/// 只有显示区域为全屏时才采用用户选的密度，其余显示区域按普通密度（见
/// `DanmakuLaneConfiguration.init(surfaceWidth:surfaceHeight:displayArea:density:)`）。
/// 间距越小、层数越多，同屏弹幕越多，也越容易互相遮挡。
struct DanmakuDensityAdmissionPolicy: Sendable, Equatable {
    /// 普通密度：同车道前后两条滚动弹幕至少隔 64pt。
    private static let normalGap = 64.0
    /// 增加密度：间距减半为 32pt，仍不叠放。
    private static let increasedGap = 32.0
    /// 允许叠放：不留间距，没有完全空闲的车道时同一车道最多叠 3 层；也是车道配置校验的层数上限。
    static let overlappingDepth = 3

    let minimumHorizontalGap: Double
    let maximumOverlapDepth: Int

    init(_ density: DanmakuDensity) {
        switch density {
        case .normal:
            minimumHorizontalGap = Self.normalGap
            maximumOverlapDepth = 1
        case .increased:
            minimumHorizontalGap = Self.increasedGap
            maximumOverlapDepth = 1
        case .overlapping:
            minimumHorizontalGap = 0
            maximumOverlapDepth = Self.overlappingDepth
        }
    }
}

extension DanmakuLaneConfiguration {
    /// 由规划画布尺寸、显示区域与密度推导车道配置；呈现控制器每次设置或规划尺寸变化都经它重建。
    init(
        surfaceWidth: Double,
        surfaceHeight: Double,
        displayArea: DanmakuDisplayArea,
        density: DanmakuDensity
    ) {
        let policy = DanmakuDensityAdmissionPolicy(displayArea == .full ? density : .normal)
        self.init(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
            minimumHorizontalGap: policy.minimumHorizontalGap,
            displayAreaFraction: displayArea.fraction,
            maximumOverlapDepth: policy.maximumOverlapDepth
        )
    }
}

/// 一条已测量的弹幕申请车道时的输入：纹理尺寸（point，含描边与阴影留白）与运动时长（媒体秒）。
public struct DanmakuLaneRequest: Sendable, Equatable {
    public let event: DanmakuEvent
    public let width: Double
    public let height: Double
    public let durationSeconds: Double

    init(
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
/// 公开只因为 `DanmakuRenderingBackend` 的签名用到它；只在本模块构造。
///
/// 时间都是媒体时间：`admittedAtSeconds` 是准入时刻，车道布局里就是弹幕自己的时间点，也是动画的开始
/// 时间；到 `expiresAtSeconds` 时车道被回收、滚动弹幕走完整张规划画布。
///
/// 几何都相对弹幕所属的锚定边，与窗口尺寸无关（取景框模型，见 docs/ARCHITECTURE.md「弹幕」）：
/// `planningWidth` 是布局时的规划画布宽度，滚动弹幕从窗口右边缘入场、在 `durationSeconds` 内走完
/// 「规划宽度 + 文字宽度」；纵向位置见 `edgeOffset`。
public struct DanmakuLanePlacement: Sendable, Equatable {
    public let request: DanmakuLaneRequest
    public let laneIndex: Int
    public let planningWidth: Double
    public let admittedAtSeconds: Double
    public let expiresAtSeconds: Double
    public let overlapDepth: Int

    init(
        request: DanmakuLaneRequest,
        laneIndex: Int,
        planningWidth: Double,
        admittedAtSeconds: Double,
        expiresAtSeconds: Double,
        overlapDepth: Int = 0
    ) {
        self.request = request
        self.laneIndex = laneIndex
        self.planningWidth = planningWidth
        self.admittedAtSeconds = admittedAtSeconds
        self.expiresAtSeconds = expiresAtSeconds
        self.overlapDepth = overlapDepth
    }

    /// 到锚定边的距离（point）：滚动与顶部弹幕是上缘到画面顶边，底部弹幕是下缘到画面底边。
    ///
    /// 只由车道号决定，不含画面高度，所以窗口变高变矮时弹幕贴着各自的边不动。
    var edgeOffset: Double {
        Double(laneIndex) * DanmakuLaneConfiguration.laneHeight
    }

    /// 占用的车道数；与 allocator 准入时的计算是同一个。
    var laneSpan: Int {
        DanmakuLaneConfiguration.laneSpan(forHeight: request.height) ?? 0
    }
}

/// 弹幕的唯一顺序：按媒体时间，同一时间按 ID。
///
/// 车道布局按它逐条准入，materializer 按它挂 layer，renderer 按它的倒序挤掉前瞻弹幕；同一份顺序保证
/// 布局与挂上的先后一致、与输入和字典遍历的顺序无关。
private func precedesInMediaTime(
    _ leftTime: Double,
    _ leftID: String,
    _ rightTime: Double,
    _ rightID: String
) -> Bool {
    leftTime == rightTime ? leftID < rightID : leftTime < rightTime
}

extension DanmakuEvent {
    /// 按 (时间, ID) 排序；见 `precedesInMediaTime`。
    static func precedes(_ left: DanmakuEvent, _ right: DanmakuEvent) -> Bool {
        precedesInMediaTime(left.timeSeconds, left.id, right.timeSeconds, right.id)
    }
}

extension DanmakuLanePlacement {
    /// 按 (进场时间, ID) 排序；车道布局里进场时间就是弹幕自己的时间，与 `DanmakuEvent.precedes` 一致。
    static func precedes(_ left: DanmakuLanePlacement, _ right: DanmakuLanePlacement) -> Bool {
        precedesInMediaTime(
            left.admittedAtSeconds,
            left.request.event.id,
            right.admittedAtSeconds,
            right.request.event.id
        )
    }
}
