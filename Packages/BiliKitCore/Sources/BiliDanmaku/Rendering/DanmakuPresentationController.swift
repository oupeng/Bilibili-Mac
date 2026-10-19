import BiliApplication
import BiliModels
import Foundation

/// 弹幕密度到车道准入参数的映射：同车道滚动弹幕的最小水平间距（point）与可叠放层数。
///
/// 只有显示区域为全屏时才采用用户选的密度，其余显示区域按普通密度（见 `updateLaneConfiguration`）。
/// 间距越小、层数越多，同屏弹幕越多，也越容易互相遮挡。
struct DanmakuDensityAdmissionPolicy: Sendable, Equatable {
    /// 普通密度：同车道前后两条滚动弹幕至少隔 64pt。
    private static let normalGap = 64.0
    /// 增加密度：间距减半为 32pt，仍不叠放。
    private static let increasedGap = 32.0
    /// 允许叠放：不留间距，没有完全空闲的车道时同一车道最多叠 3 层。
    private static let overlappingDepth = 3

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

/// 弹幕呈现端：把会话给出的分段、设置与时间线快照变成 backend 上的画面。
///
/// 画面是媒体时间的纯函数：布局表（`DanmakuLayoutCoordinator`）给出每条弹幕的车道与时长，
/// `DanmakuMaterializer` 让 backend 上的 layer 等于此刻应有的集合，layer 的运动由宿主的同步 layer
/// 按播放 item 的时间驱动。暂停、倍速与缓冲都不需要这里处理；时间线快照只用来决定何时 reconcile、
/// 画面是否静止，以及拖动进度条期间隐藏弹幕。
///
/// 拥有布局 coordinator、materializer、布局设置（画面尺寸、速度、显示区域、密度、过滤）与 surface owner；
/// 不拥有 layer 与纹理（backend），也不拥有时间线与分段加载（`DanmakuSession`）。surface owner ID 防止
/// 旧 `AVPlayerView` 的迟到 resize/detach 操作清空新宿主。换 identity、`stopPresentation`、接管或交还
/// surface 时清屏；关闭弹幕时清屏但保留布局表，打开时按当前时刻整屏挂上。
///
/// seek：时间线进入 `seeking` 且位置离开最近的落地位置超过 `seekHidingTolerance` 时隐藏整个弹幕层，
/// 不清 layer；落地（`landingGeneration` 变化或回到 `settled`）后按新时间暂存 reconcile，提交之后再显示。
/// 这是唯一用到 seek 信号的地方。
@MainActor
public final class DanmakuPresentationController: DanmakuPresentationSink {
    /// 播放中两次普通 reconcile 之间至少推进的媒体时长。
    ///
    /// 快照每秒约 30 个，不必每个都 reconcile；它必须短于 `DanmakuMaterializer.lookaheadSeconds`，
    /// 即将进场的弹幕才能提前准备纹理。调小增加主线程开销，调大则走完的 layer 留得更久。
    static let reconcileStride = 1.0
    /// seek 期间隐藏弹幕的门槛：位置离开最近一次落地位置不到这么远时不隐藏。
    ///
    /// 起播前暂停、缓冲恢复时系统也会发速率为 0 的时间跳变，时间线把它当作一次 seek，但位置几乎不变；
    /// 这时隐藏再显示只会让弹幕闪一下。调大会让小幅度的 seek 也不隐藏，调小则误判的跳变也会闪。
    static let seekHidingTolerance = 0.5

    private let backend: any DanmakuRenderingBackend
    private let coordinator = DanmakuLayoutCoordinator()
    private let materializer: DanmakuMaterializer
    private var configuration: DanmakuLaneConfiguration
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
    /// 最近一次 reconcile 时的位置；播放中推进超过 `reconcileStride` 才再 reconcile。
    private var reconciledPosition: Double?
    /// 最近一次见到的落地代号；变化时按新位置暂存 reconcile。
    private var landingGeneration: UInt64?
    /// 最近一个 `settled` 快照的位置；seek 位置离它不够远时不隐藏。
    private var settledPosition: Double?
    /// 是否因 seek 隐藏了弹幕层；落地后的暂存提交完成时取消。
    private var isHiddenForSeek = false

    public init(
        backend: any DanmakuRenderingBackend,
        configuration: DanmakuLaneConfiguration
    ) {
        self.backend = backend
        self.configuration = configuration
        materializer = DanmakuMaterializer(backend: backend)
        backend.updateSurfaceSize(
            width: configuration.surfaceWidth,
            height: configuration.surfaceHeight,
            backingScale: backingScale
        )
        coordinator.tableDidChange = { [weak self] in
            self?.reconcile(staged: true)
        }
        materializer.didCommit = { [weak self] in
            self?.revealAfterLanding()
        }
        updateLayoutParameters(debounced: false)
    }

    /// 当前布局表；reconcile 按它挂上弹幕。
    var layoutTable: [Int: DanmakuSegmentLayout] { coordinator.layouts }

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
        backend.setStill(snapshot.state != .playing || snapshot.rate == 0)

        guard snapshot.seekPhase == .settled else {
            // 拖动期间保持空屏：只隐藏，不清 layer，也不 reconcile。
            let moved = settledPosition.map {
                abs(snapshot.positionSeconds - $0) > Self.seekHidingTolerance
            }
            if !isHiddenForSeek, moved ?? true {
                isHiddenForSeek = true
                backend.setHidden(true)
            }
            backend.recompositeIfStill()
            return
        }
        settledPosition = snapshot.positionSeconds
        let landed = landingGeneration != snapshot.landingGeneration
        landingGeneration = snapshot.landingGeneration
        if landed || isHiddenForSeek {
            reconcile(staged: true)
        } else if reconciledPosition.map({
            abs(snapshot.positionSeconds - $0) >= Self.reconcileStride
        }) ?? true {
            reconcile(staged: false)
        } else {
            backend.recompositeIfStill()
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
            reconcile(staged: true)
        } else {
            materializer.clear()
            backend.recompositeIfStill()
        }
    }

    public func setFilter(_ filter: DanmakuFilter) {
        guard self.filter != filter else { return }
        self.filter = filter
        updateLayoutParameters(debounced: false)
    }

    public func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {
        guard self.speedLevel != speedLevel else { return }
        self.speedLevel = speedLevel
        updateLayoutParameters(debounced: false)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        backend.setOpacity(opacity)
    }

    public func setDisplayArea(_ displayArea: DanmakuDisplayArea) {
        guard self.displayArea != displayArea else { return }
        self.displayArea = displayArea
        updateLaneConfiguration()
        updateLayoutParameters(debounced: false)
    }

    public func setDensity(_ density: DanmakuDensity) {
        guard self.density != density else { return }
        self.density = density
        updateLaneConfiguration()
        updateLayoutParameters(debounced: false)
    }

    public func stopPresentation() {
        identity = nil
        resetTimelineState()
        backend.stop()
    }

    /// 新 overlay 接管 surface：记下 owner、清屏，再按当前时刻整屏挂上；同一 owner 重复调用是空操作。
    @discardableResult
    public func attachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID != ownerID else { return true }
        surfaceOwnerID = ownerID
        materializer.clear()
        reconcile(staged: true)
        return true
    }

    /// 只有当前 owner 能交还 surface，交还时清屏；返回是否生效。
    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        materializer.clear()
        return true
    }

    /// 只接受当前 owner 的尺寸更新；返回是否生效。
    ///
    /// 已有布局表时按新尺寸重新布局要去抖（live resize），期间屏上沿用旧布局。
    @discardableResult
    public func updateSurface(
        width: Double,
        height: Double,
        backingScale: Double = 2,
        ownerID: UUID
    ) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        let normalizedScale = DanmakuTextureRasterizer.normalizedBackingScale(backingScale)
        self.backingScale = normalizedScale
        backend.updateSurfaceSize(width: width, height: height, backingScale: normalizedScale)
        materializer.setBackingScale(normalizedScale)
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: width,
            surfaceHeight: height,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: configuration.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: configuration.displayAreaFraction,
            maximumOverlapDepth: configuration.maximumOverlapDepth
        )
        updateLayoutParameters(debounced: true)
        return true
    }

    /// 布局表在 `latestSnapshot` 时刻应有的弹幕挂到 backend 上；弹幕关闭或还没有快照时什么都不做。
    private func reconcile(staged: Bool) {
        guard let snapshot = latestSnapshot, snapshot.identity == identity else { return }
        guard isEnabled else {
            revealAfterLanding()
            return
        }
        reconciledPosition = snapshot.positionSeconds
        materializer.reconcile(
            table: layoutTable,
            position: snapshot.positionSeconds,
            staged: staged
        )
    }

    /// 暂存提交完成：已经落地时重新显示弹幕层；仍在拖动时保持隐藏。
    private func revealAfterLanding() {
        guard isHiddenForSeek, latestSnapshot?.seekPhase == .settled else { return }
        isHiddenForSeek = false
        backend.setHidden(false)
        backend.recompositeIfStill()
    }

    /// 换 identity 或停止：丢弃布局表与时间线状态并清屏。
    private func resetTimelineState() {
        coordinator.reset()
        materializer.clear()
        latestSnapshot = nil
        reconciledPosition = nil
        landingGeneration = nil
        settledPosition = nil
        if isHiddenForSeek {
            isHiddenForSeek = false
            backend.setHidden(false)
        }
        backend.recompositeIfStill()
    }

    /// 按显示区域与密度重建车道配置；画面尺寸不变。
    private func updateLaneConfiguration() {
        let effectiveDensity: DanmakuDensity =
            displayArea == .full ? density : .normal
        let policy = DanmakuDensityAdmissionPolicy(effectiveDensity)
        configuration = DanmakuLaneConfiguration(
            surfaceWidth: configuration.surfaceWidth,
            surfaceHeight: configuration.surfaceHeight,
            laneHeight: configuration.laneHeight,
            minimumHorizontalGap: policy.minimumHorizontalGap,
            maximumActiveCount: configuration.maximumActiveCount,
            displayAreaFraction: displayArea.fraction,
            maximumOverlapDepth: policy.maximumOverlapDepth
        )
    }

    /// 把当前设置交给布局 coordinator；画面尚未布局（尺寸为 0）时不布局。
    private func updateLayoutParameters(debounced: Bool) {
        let parameters =
            configuration.isValid
            ? DanmakuLayoutParameters(
                configuration: configuration,
                speedLevel: speedLevel,
                backingScale: backingScale,
                filter: filter
            ) : nil
        coordinator.setParameters(parameters, debounced: debounced)
    }
}
