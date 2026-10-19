import BiliApplication
import BiliModels
import Foundation

/// 车道分配的几何参数，由 `DanmakuPresentationController` 按画面尺寸、显示区域与密度推导
/// （`init(surfaceWidth:surfaceHeight:displayArea:density:)`），经车道布局交给 `DanmakuLaneAllocator`。
///
/// 车道高度与同屏上限是产品常量，不随设置变化。任一参数变化，布局表都按新参数整张重排；`isValid`
/// 不成立时 allocator 拒绝全部请求，画面尚未布局时也就不布局。
public struct DanmakuLaneConfiguration: Sendable, Equatable {
    /// 同屏弹幕数的硬上限：车道布局在任一媒体时刻最多准入这么多条，超出的按 (时间, ID) 顺序丢弃；
    /// 也是纹理准备 owner 的未完成请求上限。
    ///
    /// 它限定的是 Core Animation 合成与纹理内存的最坏情况：调大让高密度时段同屏更多，
    /// 但合成与内存开销随之上升；调小则高峰期更早丢弃。
    public static let hardMaximumActiveCount = 640

    /// 车道基元高度（point），与最大字号同为 36；更高的纹理占用连续多条车道。
    ///
    /// 调大同屏行数变少，调小则更多弹幕跨多条车道。
    public static let laneHeight = 36.0

    /// 车道数的上限，只防止极端画面高度换算成 `Int` 时溢出。
    ///
    /// 8K 竖屏也只有约 120 条车道，这个值远在任何真实画面之上，不影响布局；它与同屏上限无关，
    /// 不复用 `hardMaximumActiveCount`。
    static let maximumLaneCount = 4_096

    public let surfaceWidth: Double
    public let surfaceHeight: Double
    /// 同一车道前后两条滚动弹幕之间的最小水平间距（point），由密度决定。
    public let minimumHorizontalGap: Double
    /// 可放弹幕的画面高度比例（0...1），车道数按画面高度乘以它计算；滚动与顶部弹幕从顶边往下排，
    /// 底部弹幕从底边往上排。
    public let displayAreaFraction: Double
    /// 同一车道允许叠放的层数；1 表示不叠放，大于 1 时没有完全空闲的车道才按层叠放。
    public let maximumOverlapDepth: Int

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
/// 时间都是媒体时间：`admittedAtSeconds` 是准入时刻，车道布局里就是弹幕自己的时间点，也是动画的开始
/// 时间；到 `expiresAtSeconds` 时车道被回收、layer 走完。`originY` 自画面顶边向下计算。
/// `surfaceWidthAtAdmission` 是布局时的画面宽度：滚动弹幕从这里入场，renderer 按它设定运动起点；
/// 画面尺寸变了、按新尺寸重新布局之前，屏上仍按旧布局运动。
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
