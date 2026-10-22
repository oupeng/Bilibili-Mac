import BiliApplication
import BiliModels
import Foundation

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

/// 弹幕呈现端：把会话给出的分段、设置与时间线快照变成 backend 上的画面。
///
/// 同一组已缓存分段与设置下，画面是媒体时间与窗口尺寸的纯函数：布局表（`DanmakuLayoutCoordinator`）
/// 给出每条弹幕的车道与时长，`DanmakuMaterializer` 让 backend 上的 layer 等于此刻取景框里应有的集合，
/// layer 的运动由宿主的时钟层按播放 item 的 timebase 驱动。暂停、倍速与缓冲都不需要这里处理。
///
/// 单一时间源：在屏集合、对齐位置、覆盖区间、迟到纹理与腾纹理字节都按时钟层此刻的显示时间 D(now)
/// （`DanmakuDisplayClock`，宿主接管 surface 时交来）计算，与画面上弹幕运动的是同一条线。时间线快照与时钟层
/// 之间有偏差（seek 起播时快照领先、卡顿时快照速率仍是 1、未缓冲拖动时快照领先几十秒、4x 跳变风暴时快照
/// 回跳），按快照算会让屏上集合与画面错开。快照只剩两个用途：确认 identity，以及作为「该检查一下了」的
/// 节拍；时钟层写入后经 `displayClockDidChange(ownerID:)` 触发同一次检查（暂停中 seek 没有后续快照）。每个
/// 入口只读一次 D，作为参数传给 materializer，不在下游再读；读不到 D（时钟从未绑定、换绑后新纪元还没写入、
/// 没有接管 surface 的时钟）时什么都不做，等下一次触发。
///
/// 主线程求值晚于上屏：按 D(now) 删掉「已走完」的弹幕要晚一到几帧才上屏，这期间时钟若被往回改写（速率 0
/// 时往回 seek、换绑），这些弹幕会提前缺席，直到唤醒触发的重新对齐补回来。已挂上的 layer 只在自己的动画
/// 区间里可见，所以错误只可能是缺席，不会错位或多余。
///
/// 取景框：布局表按规划画布排一次，规划尺寸取承载窗口的屏幕尺寸与窗口尺寸的较大者（逐个维度）。规划
/// 尺寸、backing scale 或设置变化时整张重排，在一次整屏暂存提交里瞬时替换整屏；分段到达只填补原本空着
/// 的区域，它的暂存可以被重新对齐取代（见 `DanmakuMaterializer.StagedCommitKind`）。窗口尺寸只决定露出
/// 布局表的哪一部分，变化时不重排，只移动 backend 的锚定边并按新取景框普通对齐（见
/// docs/ARCHITECTURE.md「弹幕」）。
///
/// 拥有布局 coordinator、materializer、布局设置（规划尺寸、速度、显示区域、密度、过滤）、窗口尺寸与 surface owner；
/// 不拥有 layer 与纹理（backend），也不拥有时间线与分段加载（`DanmakuSession`）。surface owner ID 防止
/// 旧 `AVPlayerView` 的迟到 resize/detach 操作清空新宿主。换 identity、`stopPresentation`、接管或交还
/// surface 时清屏；关闭弹幕时清屏但保留布局表，打开时按当前时刻整屏挂上。
///
/// 何时对齐只看 D 与上次对齐位置，不识别 seek 或拖动，也不读不连续代号：位置落在上次对齐的覆盖
/// 区间 [上次对齐位置, 上次对齐位置 + `alignmentCoverageSeconds`) 里时，屏上已挂的就是此刻应有的，
/// 只在推进满 `reconcileStride` 时普通对齐；越出区间（向前跳出或回跳）时重新对齐，暂存与否由
/// materializer 按缺纹理的情况决定（见 `DanmakuMaterializer.realign()`）。恢复播放与向前的 timebase 重锚
/// 时 D 还在区间里，什么都不做；起播与卡顿恢复时 timebase 后退一个音频输出延迟，D 随之回跳，触发一次重新
/// 对齐：纹理都在缓存里时一次调用里完成，若此时还有分段到达的可取代暂存在等纹理，就会部分提交、其余逐条
/// 出现。弹幕不隐藏也不清屏，屏上的 layer 一直跟随媒体时间。
@MainActor
public final class DanmakuPresentationController: DanmakuPresentationSink {
    /// 播放中两次普通 reconcile 之间至少推进的媒体时长。
    ///
    /// 检查由快照（每秒约 30 个）与时钟写入触发，不必每次都 reconcile；它必须短于 `DanmakuMaterializer.lookaheadSeconds`，
    /// 即将进场的弹幕才能提前准备纹理。调小增加主线程开销，调大则走完的 layer 留得更久。
    static let reconcileStride = 1.0

    /// 覆盖区间末端到前瞻末端之间留给准备纹理的媒体时长。
    ///
    /// 调小则区间末端附近进场的弹幕准备时间更少、更容易迟到；调大则区间变短，更多正常推进被当作
    /// 重新对齐。它必须让区间仍长于 `reconcileStride` 加相邻两次检查的间隔（见 `alignmentCoverageSeconds`）。
    static let texturePreparationMarginSeconds = 0.5

    /// 上次对齐覆盖的媒体时长：位置在 [上次对齐位置, 上次对齐位置 + 它) 里时不必重新对齐。
    ///
    /// 上次对齐挂上了进场时间不晚于「上次对齐位置 + 前瞻」的弹幕，区间由前瞻减去准备余量得出，所以总在
    /// 前瞻之内。它必须长于 `reconcileStride` 加相邻两次检查的间隔：检查主要由快照触发，周期观察器按 item
    /// 时间每 1/30 媒体秒触发一次，但弹幕会话经只保留最新值的 AsyncStream 收快照，主线程忙时快照会被合并，
    /// 两次检查之间 D 推进的量可能远大于此。推进大到越过步长、直接落到区间外时按重新对齐处理：
    /// - 落点不超过「上次对齐位置 + 前瞻」：缺纹理的几乎只有前瞻弹幕，走普通增量，画面不变。
    /// - 卡顿越过了前瞻：(上次对齐位置 + 前瞻, 落点] 里进场的弹幕从没请求过纹理，密集时会整屏暂存一次。
    static let alignmentCoverageSeconds =
        DanmakuMaterializer.lookaheadSeconds - texturePreparationMarginSeconds

    private let backend: any DanmakuRenderingBackend
    private let coordinator = DanmakuLayoutCoordinator()
    private let materializer: DanmakuMaterializer
    /// 当前 surface owner 的时钟，D(now) 的唯一来源；与 materializer 共享，它在纹理异步完成时自己读。
    private let clockBox: DisplayClockBox
    /// 窗口（取景框）尺寸（point）；尚未布局时为 0，这时什么都不显示。
    private var surfaceWidth = 0.0
    private var surfaceHeight = 0.0
    /// 规划画布尺寸（point），布局表按它排；不小于窗口尺寸，尚未布局时为 0，这时不布局。
    private var planningWidth = 0.0
    private var planningHeight = 0.0
    private var speedLevel = DanmakuSpeedLevel.default
    private var displayArea = DanmakuDisplayArea.default
    private var density = DanmakuDensity.default
    private var filter = DanmakuFilter()
    private var isEnabled = true
    /// 当前呈现的播放 identity；变化时清屏并丢弃布局表。
    private var identity: PlaybackItemIdentity?
    /// 当前持有 surface 的 overlay；只有它的尺寸更新与 detach 生效。
    private var surfaceOwnerID: UUID?
    /// 当前 surface 的 backing scale；纹理与测量都按它计算。
    private var backingScale = DanmakuTextureRasterizer.defaultBackingScale
    /// 最近一次快照；只用来确认已有当前 identity 的时间线（换 item 后要等新 item 的快照），不提供位置。
    private var latestSnapshot: PlaybackTimelineSnapshot?
    /// 最近一次对齐时的 D，覆盖区间从这里算起。
    ///
    /// 为 nil 时下一次检查重新对齐。任何一次 reconcile 都更新它，换 identity、停止、换 item、接管与交还
    /// surface 时清掉。
    private var alignedPosition: Double?

    /// 窗口与屏幕尺寸由接管 surface 的宿主经 `updateSurface` 给出，之前不布局。
    public init(backend: any DanmakuRenderingBackend) {
        self.backend = backend
        let clockBox = DisplayClockBox()
        self.clockBox = clockBox
        materializer = DanmakuMaterializer(backend: backend) {
            clockBox.clock?.displayTime()
        }
        coordinator.tableDidChange = { [weak self] change in
            switch change {
            case .relayout:
                self?.reconcileAtDisplayTime(.staged(.wholeScreen))
            case .segmentsAdded:
                self?.reconcileAtDisplayTime(.staged(.supersedable))
            }
        }
    }

    /// 当前布局表；reconcile 按它挂上弹幕。
    var layoutTable: [Int: DanmakuSegmentLayout] { coordinator.layouts }

    /// 当前窗口在规划画布上的取景框；可见车道数与规划车道数用同一个显示区域比例。
    var viewport: DanmakuViewport {
        DanmakuViewport(
            width: surfaceWidth,
            height: surfaceHeight,
            displayAreaFraction: displayArea.fraction
        )
    }

    public func apply(_ snapshot: PlaybackTimelineSnapshot) {
        guard let snapshotIdentity = snapshot.identity else {
            stopPresentation()
            return
        }
        if identity != snapshotIdentity {
            identity = snapshotIdentity
            resetTimelineState()
        }
        latestSnapshot = snapshot
        evaluate()
    }

    /// 时钟层写入了新的直线（速率变化、时间跳变、换绑后的第一次同步）：按新的 D(now) 检查一次；只接受当前 owner。
    ///
    /// 由宿主在主线程调用，多次写入可能合并成一次；暂停中 seek 时没有后续快照，靠它重新对齐。
    public func displayClockDidChange(ownerID: UUID) {
        guard surfaceOwnerID == ownerID else { return }
        evaluate()
    }

    /// 按此刻的 D 决定对齐方式：越出上次对齐的覆盖区间重新对齐，在区间里推进满步长普通对齐。
    private func evaluate() {
        guard canAlign, let position = clockBox.clock?.displayTime() else { return }
        guard let aligned = alignedPosition,
            position >= aligned,
            position < aligned + Self.alignmentCoverageSeconds
        else {
            reconcile(.realign, at: position)
            return
        }
        if position - aligned >= Self.reconcileStride {
            reconcile(.incremental, at: position)
        }
    }

    public func setSegments(
        _ segments: [Int: [DanmakuEvent]],
        for identity: PlaybackItemIdentity
    ) {
        guard self.identity == identity else { return }
        coordinator.setSegments(segments)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            reconcileAtDisplayTime(.staged(.wholeScreen))
        } else {
            materializer.clear()
        }
    }

    public func setFilter(_ filter: DanmakuFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        updateLayoutParameters()
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        guard self.speedLevel != speedLevel else { return }
        self.speedLevel = speedLevel
        updateLayoutParameters()
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        backend.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        guard self.displayArea != displayArea else { return }
        self.displayArea = displayArea
        updateLayoutParameters()
    }

    public func setDensity(_ density: DanmakuDensity) {
        guard self.density != density else { return }
        self.density = density
        updateLayoutParameters()
    }

    public func stopPresentation() {
        identity = nil
        resetTimelineState()
        backend.stop()
    }

    /// 新 overlay 接管 surface：记下 owner 与它的时钟、清屏，再按此刻的 D 整屏挂上；同一 owner 重复调用是空操作。
    ///
    /// 控制器持有 `clock` 直到交还；时钟回调宿主时只弱引用宿主，不经过控制器，所以不成环。
    public func attachSurface(ownerID: UUID, clock: any DanmakuDisplayClock) {
        guard surfaceOwnerID != ownerID else { return }
        surfaceOwnerID = ownerID
        clockBox.clock = clock
        alignedPosition = nil
        materializer.clear()
        reconcileAtDisplayTime(.staged(.wholeScreen))
    }

    /// 只有当前 owner 能交还 surface，交还时清屏并放下它的时钟；返回是否生效。
    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        clockBox.clock = nil
        alignedPosition = nil
        materializer.clear()
        return true
    }

    /// 宿主的时钟层即将换绑到另一个播放 item：先清屏，再由宿主换绑；只接受当前 owner。
    ///
    /// 时钟层换绑后时间立刻按新 item 走，旧 layer 留着会在新时间线上错位，所以必须先清。布局表保留
    /// （同一视频换线路或清晰度时仍然有效）。上次对齐位置清掉，新 item 有 D 之后的第一次检查一定重新对齐。
    /// 最近快照也清掉，等新 item 自己的快照来确认 identity：换的若是另一个视频，旧快照的 identity 仍是旧视频，
    /// 留着的话新 item 的 D 一到就会把旧视频的布局表按新视频的时刻挂上，要等新视频的快照到达、换 identity
    /// 时才清掉。宿主随后换绑时钟，新 timebase 第一次写入之前读不到 D；新 item 的快照与新纪元的 D 都有了之后
    /// （哪个后到由哪个触发检查）按 D 重新对齐，纹理多半还在缓存里，一次整屏挂上。
    public func playerItemWillChange(ownerID: UUID) {
        guard surfaceOwnerID == ownerID else { return }
        materializer.clear()
        latestSnapshot = nil
        alignedPosition = nil
    }

    /// 只接受当前 owner 的尺寸更新：`width`/`height` 是窗口里弹幕画面的尺寸，`screenWidth`/`screenHeight`
    /// 是承载窗口的屏幕尺寸（point，宿主取不到屏幕时传 0）。
    ///
    /// 规划尺寸逐个维度取屏幕与窗口的较大者，所以窗口跨屏变得比屏幕大时，新表排好后也不会露出规划画布
    /// 之外；规划尺寸或 scale 变了才整张重排。窗口尺寸变化本身只移动锚定边并按新取景框普通对齐：放大时补上
    /// 新露出的、正在飞的弹幕（缺纹理的就绪后出现，暂存提交未完成时等提交），缩小时立即移除被裁掉的，不做
    /// 暂存的整屏替换。
    public func updateSurface(
        width: Double,
        height: Double,
        screenWidth: Double,
        screenHeight: Double,
        backingScale: Double,
        ownerID: UUID
    ) {
        guard surfaceOwnerID == ownerID else { return }
        let position = clockBox.clock?.displayTime()
        let normalizedScale = DanmakuTextureRasterizer.normalizedBackingScale(backingScale)
        self.backingScale = normalizedScale
        // 顺序是契约：backend 换 scale 时静默取消在途准备（不回调），materializer 随后作废记录、在有暂存时按
        // 此刻的 D 重开。反过来的话，重开发出的请求会被随后的取消吞掉，暂存永远等不齐。
        backend.updateSurfaceSize(width: width, height: height, backingScale: normalizedScale)
        materializer.setBackingScale(normalizedScale, at: position)
        surfaceWidth = width
        surfaceHeight = height
        planningWidth = Self.planningExtent(window: width, screen: screenWidth)
        planningHeight = Self.planningExtent(window: height, screen: screenHeight)
        updateLayoutParameters()
        if let position {
            reconcile(.incremental, at: position)
        }
    }

    /// 规划画布在一个维度上的长度：屏幕与窗口的较大者；无效值按 0 处理。
    private static func planningExtent(window: Double, screen: Double) -> Double {
        max(window.isFinite ? window : 0, screen.isFinite ? screen : 0, 0)
    }

    /// 是否可以对齐：已有当前 identity 的快照且弹幕开着；另外还要读得到 D，由各入口自己读。
    private var canAlign: Bool {
        identity != nil && latestSnapshot?.identity == identity && isEnabled
    }

    /// 读一次此刻的 D，再按它 reconcile；读不到时什么都不做。
    ///
    /// 用于不经 `evaluate` 的入口：布局表替换、打开弹幕、接管 surface。
    private func reconcileAtDisplayTime(_ mode: DanmakuMaterializer.Mode) {
        guard let position = clockBox.clock?.displayTime() else { return }
        reconcile(mode, at: position)
    }

    /// 布局表在 `position`（入口读到的 D）时刻应有的弹幕挂到 backend 上；不满足 `canAlign` 时什么都不做。
    private func reconcile(_ mode: DanmakuMaterializer.Mode, at position: Double) {
        guard canAlign else { return }
        alignedPosition = position
        materializer.reconcile(
            table: layoutTable,
            position: position,
            viewport: viewport,
            mode: mode
        )
    }

    /// 换 identity 或停止：丢弃布局表与时间线状态并清屏。
    private func resetTimelineState() {
        coordinator.reset()
        materializer.clear()
        latestSnapshot = nil
        alignedPosition = nil
    }

    /// 把当前设置与规划尺寸交给布局 coordinator；与上次相同时 coordinator 什么都不做，画面尚未布局
    /// （尺寸为 0）时不布局。
    private func updateLayoutParameters() {
        let configuration = DanmakuLaneConfiguration(
            surfaceWidth: planningWidth,
            surfaceHeight: planningHeight,
            displayArea: displayArea,
            density: density
        )
        let parameters =
            configuration.isValid
            ? DanmakuLayoutParameters(
                configuration: configuration,
                speedLevel: speedLevel,
                backingScale: backingScale,
                filter: filter
            ) : nil
        coordinator.setParameters(parameters)
    }
}

/// 呈现控制器与 materializer 共用的当前时钟引用，只在主线程读写；控制器是唯一写入者（接管与交还 surface）。
@MainActor
final class DisplayClockBox {
    var clock: (any DanmakuDisplayClock)?
}
