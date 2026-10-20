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
/// layer 的运动由宿主的时钟层按播放 item 的 timebase 驱动。暂停、倍速与缓冲都不需要这里处理；时间线快照
/// 只用来决定何时 reconcile。
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
/// 何时对齐只看快照位置与上次对齐位置，不识别 seek 或拖动，也不读不连续代号：位置落在上次对齐的覆盖
/// 区间 [上次对齐位置, 上次对齐位置 + `alignmentCoverageSeconds`) 里时，屏上已挂的就是此刻应有的，
/// 只在推进满 `reconcileStride` 时普通对齐；越出区间（向前跳出或回跳）时重新对齐，暂存与否由
/// materializer 按缺纹理的情况决定（见 `DanmakuMaterializer.realign()`）。恢复播放、timebase 重锚与
/// 缓冲恢复时位置还在区间里，什么都不做。弹幕不隐藏也不清屏，屏上的 layer 一直跟随媒体时间。
@MainActor
public final class DanmakuPresentationController: DanmakuPresentationSink {
    /// 播放中两次普通 reconcile 之间至少推进的媒体时长。
    ///
    /// 快照每秒约 30 个，不必每个都 reconcile；它必须短于 `DanmakuMaterializer.lookaheadSeconds`，
    /// 即将进场的弹幕才能提前准备纹理。调小增加主线程开销，调大则走完的 layer 留得更久。
    static let reconcileStride = 1.0

    /// 覆盖区间末端到前瞻末端之间留给准备纹理的媒体时长。
    ///
    /// 调小则区间末端附近进场的弹幕准备时间更少、更容易迟到；调大则区间变短，更多正常推进被当作
    /// 重新对齐。它必须让区间仍长于 `reconcileStride` 加相邻快照的间隔（见 `alignmentCoverageSeconds`）。
    static let texturePreparationMarginSeconds = 0.5

    /// 上次对齐覆盖的媒体时长：位置在 [上次对齐位置, 上次对齐位置 + 它) 里时不必重新对齐。
    ///
    /// 上次对齐挂上了进场时间不晚于「上次对齐位置 + 前瞻」的弹幕，区间由前瞻减去准备余量得出，所以总在
    /// 前瞻之内。它必须长于 `reconcileStride` 加相邻快照的间隔：周期观察器按 item 时间每 1/30 媒体秒触发
    /// 一次，但弹幕会话经只保留最新值的 AsyncStream 收快照，主线程忙时快照会被合并，间隔可能远大于此。
    /// 间隔大到越过步长、直接落到区间外时按重新对齐处理：
    /// - 落点不超过「上次对齐位置 + 前瞻」：缺纹理的几乎只有前瞻弹幕，走普通增量，画面不变。
    /// - 卡顿越过了前瞻：(上次对齐位置 + 前瞻, 落点] 里进场的弹幕从没请求过纹理，密集时会整屏暂存一次。
    static let alignmentCoverageSeconds =
        DanmakuMaterializer.lookaheadSeconds - texturePreparationMarginSeconds

    private let backend: any DanmakuRenderingBackend
    private let coordinator = DanmakuLayoutCoordinator()
    private let materializer: DanmakuMaterializer
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
    /// 最近一次快照；reconcile 用它的位置作为当前媒体时间。
    private var latestSnapshot: PlaybackTimelineSnapshot?
    /// 最近一次对齐时的位置，覆盖区间从这里算起。
    ///
    /// 为 nil 时下一个快照重新对齐。任何一次 reconcile 都更新它，换 identity、停止与换 item 时清掉。
    private var alignedPosition: Double?

    /// 窗口与屏幕尺寸由接管 surface 的宿主经 `updateSurface` 给出，之前不布局。
    public init(backend: any DanmakuRenderingBackend) {
        self.backend = backend
        materializer = DanmakuMaterializer(backend: backend)
        coordinator.tableDidChange = { [weak self] change in
            switch change {
            case .relayout:
                self?.reconcile(.staged(.wholeScreen))
            case .segmentsAdded:
                self?.reconcile(.staged(.supersedable))
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

        let position = snapshot.positionSeconds
        guard let aligned = alignedPosition,
            position >= aligned,
            position < aligned + Self.alignmentCoverageSeconds
        else {
            reconcile(.realign)
            return
        }
        if position - aligned >= Self.reconcileStride {
            reconcile(.incremental)
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
            reconcile(.staged(.wholeScreen))
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

    /// 新 overlay 接管 surface：记下 owner、清屏，再按当前时刻整屏挂上；同一 owner 重复调用是空操作。
    public func attachSurface(ownerID: UUID) {
        guard surfaceOwnerID != ownerID else { return }
        surfaceOwnerID = ownerID
        materializer.clear()
        reconcile(.staged(.wholeScreen))
    }

    /// 只有当前 owner 能交还 surface，交还时清屏；返回是否生效。
    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        materializer.clear()
        return true
    }

    /// 宿主的时钟层即将换绑到另一个播放 item：先清屏，再由宿主换绑；只接受当前 owner。
    ///
    /// 时钟层换绑后时间立刻按新 item 走，旧 layer 留着会在新时间线上错位，所以必须先清。布局表保留
    /// （同一视频换线路或清晰度时仍然有效）。最近快照与上次对齐位置一并清掉：旧 item 的位置在新时间线上
    /// 没有意义，留着的话新 item 第一个快照之前的 resize 或布局表替换会按它对齐，新位置又可能落在它的
    /// 覆盖区间里，清空的屏就不再挂上。新 item 的第一个快照到来之前不对齐，到来时按它的时刻重新对齐，
    /// 纹理多半还在缓存里，一次整屏挂上。
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
        let normalizedScale = DanmakuTextureRasterizer.normalizedBackingScale(backingScale)
        self.backingScale = normalizedScale
        backend.updateSurfaceSize(width: width, height: height, backingScale: normalizedScale)
        materializer.setBackingScale(normalizedScale)
        surfaceWidth = width
        surfaceHeight = height
        planningWidth = Self.planningExtent(window: width, screen: screenWidth)
        planningHeight = Self.planningExtent(window: height, screen: screenHeight)
        updateLayoutParameters()
        reconcile(.incremental)
    }

    /// 规划画布在一个维度上的长度：屏幕与窗口的较大者；无效值按 0 处理。
    private static func planningExtent(window: Double, screen: Double) -> Double {
        max(window.isFinite ? window : 0, screen.isFinite ? screen : 0, 0)
    }

    /// 布局表在 `latestSnapshot` 时刻应有的弹幕挂到 backend 上；弹幕关闭或还没有快照时什么都不做。
    private func reconcile(_ mode: DanmakuMaterializer.Mode) {
        guard let snapshot = latestSnapshot, snapshot.identity == identity, isEnabled else {
            return
        }
        alignedPosition = snapshot.positionSeconds
        materializer.reconcile(
            table: layoutTable,
            position: snapshot.positionSeconds,
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
