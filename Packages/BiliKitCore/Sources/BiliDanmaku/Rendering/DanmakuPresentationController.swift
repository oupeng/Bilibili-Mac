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
    /// 由画面尺寸、显示区域与密度推导车道配置；呈现控制器每次设置或尺寸变化都经它重建。
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
/// 同一组已缓存分段与设置下，画面是媒体时间的纯函数：布局表（`DanmakuLayoutCoordinator`）给出每条
/// 弹幕的车道与时长，`DanmakuMaterializer` 让 backend 上的 layer 等于此刻应有的集合，layer 的运动由
/// 宿主的同步 layer 按播放 item 的时间驱动。暂停、倍速与缓冲都不需要这里处理；时间线快照只用来决定何时 reconcile。
///
/// 拥有布局 coordinator、materializer、布局设置（画面尺寸、速度、显示区域、密度、过滤）与 surface owner；
/// 不拥有 layer 与纹理（backend），也不拥有时间线与分段加载（`DanmakuSession`）。surface owner ID 防止
/// 旧 `AVPlayerView` 的迟到 resize/detach 操作清空新宿主。换 identity、`stopPresentation`、接管或交还
/// surface 时清屏；关闭弹幕时清屏但保留布局表，打开时按当前时刻整屏挂上。
///
/// 设置（屏蔽、类型显隐、密度、速度、显示区域）或画面尺寸（全屏、缩放、live resize 去抖后）变化引起的
/// 整张重排交叉淡化成新布局；分段到达、上一段晚到、打开弹幕、换 item 与 seek 都瞬时替换。
///
/// 不连续：`discontinuityGeneration` 变化（seek、换项、续播起点、系统时间跳变）时先结束进行中的淡化，
/// 再按快照位置暂存提交一次，否则按推进步长普通对齐。弹幕不隐藏也不清屏，屏上的 layer 一直跟随媒体时间。原生拖动每一步都
/// 推进不连续代号，每步都发起一次暂存提交并作废上一步还没完成的纹理准备（排队中的栅格化随之取消），
/// 最后一步之后自然提交到落点。从暂停恢复播放时系统报的原地跳变也推进代号，只多做一次内容相同的
/// 提交，画面不变。
@MainActor
public final class DanmakuPresentationController: DanmakuPresentationSink {
    /// 播放中两次普通 reconcile 之间至少推进的媒体时长。
    ///
    /// 快照每秒约 30 个，不必每个都 reconcile；它必须短于 `DanmakuMaterializer.lookaheadSeconds`，
    /// 即将进场的弹幕才能提前准备纹理。调小增加主线程开销，调大则走完的 layer 留得更久。
    static let reconcileStride = 1.0

    private let backend: any DanmakuRenderingBackend
    private let coordinator = DanmakuLayoutCoordinator()
    private let materializer: DanmakuMaterializer
    /// 当前 surface 的尺寸（point）；尚未布局时为 0，这时不布局。
    private var surfaceWidth = 0.0
    private var surfaceHeight = 0.0
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
    /// 最近一次见到的不连续代号；变化时按新位置暂存 reconcile。
    private var discontinuityGeneration: UInt64?

    /// 画面尺寸由接管 surface 的宿主经 `updateSurface` 给出，之前不布局。
    public init(backend: any DanmakuRenderingBackend) {
        self.backend = backend
        materializer = DanmakuMaterializer(backend: backend)
        coordinator.tableDidChange = { [weak self] isSettingsRelayout in
            if isSettingsRelayout {
                self?.reconcileWithCrossfade()
            } else {
                self?.reconcile(staged: true)
            }
        }
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

        let isDiscontinuous = discontinuityGeneration != snapshot.discontinuityGeneration
        discontinuityGeneration = snapshot.discontinuityGeneration
        if isDiscontinuous {
            // seek、换项等不连续一律瞬时替换，进行中的交叉淡化立即结束。
            materializer.finishCrossfade()
            reconcile(staged: true)
        } else if reconciledPosition.map({
            abs(snapshot.positionSeconds - $0) >= Self.reconcileStride
        }) ?? true {
            reconcile(staged: false)
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
        updateLayoutParameters(debounced: false)
    }

    public func setDensity(_ density: DanmakuDensity) {
        guard self.density != density else { return }
        self.density = density
        updateLayoutParameters(debounced: false)
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
        reconcile(staged: true)
    }

    /// 只有当前 owner 能交还 surface，交还时清屏；返回是否生效。
    @discardableResult
    public func detachSurface(ownerID: UUID) -> Bool {
        guard surfaceOwnerID == ownerID else { return false }
        surfaceOwnerID = nil
        materializer.clear()
        return true
    }

    /// 宿主的同步 layer 即将换绑到另一个播放 item：先清屏，再由宿主换绑；只接受当前 owner。
    ///
    /// 同步 layer 换绑后时间立刻按新 item 走，旧 layer 留着会在新时间线上错位，所以必须先清。布局表保留
    /// （同一视频换线路或清晰度时仍然有效），下一个快照按新 item 的时刻整屏挂上。
    public func playerItemWillChange(ownerID: UUID) {
        guard surfaceOwnerID == ownerID else { return }
        materializer.clear()
        discontinuityGeneration = nil
    }

    /// 只接受当前 owner 的尺寸更新。
    ///
    /// 已有布局表时按新尺寸重新布局要去抖（live resize），期间屏上沿用旧布局。
    public func updateSurface(
        width: Double,
        height: Double,
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
        updateLayoutParameters(debounced: true)
    }

    /// 布局表在 `latestSnapshot` 时刻应有的弹幕挂到 backend 上；弹幕关闭或还没有快照时什么都不做。
    private func reconcile(staged: Bool) {
        guard let snapshot = latestSnapshot, snapshot.identity == identity, isEnabled else {
            return
        }
        reconciledPosition = snapshot.positionSeconds
        materializer.reconcile(
            table: layoutTable,
            position: snapshot.positionSeconds,
            staged: staged
        )
    }

    /// 设置或画面尺寸变化后的整屏重排：屏上已有弹幕时交叉淡化成新布局，否则直接暂存提交。
    ///
    /// 旧组淡出期间按快照的速率继续走（未在播放时为 0），淡化本身按挂钟走完，暂停时同样完成。
    private func reconcileWithCrossfade() {
        guard let snapshot = latestSnapshot, snapshot.identity == identity, isEnabled else {
            return
        }
        guard materializer.hasInstalledLayers else {
            reconcile(staged: true)
            return
        }
        reconciledPosition = snapshot.positionSeconds
        materializer.reconcileWithCrossfade(
            table: layoutTable,
            position: snapshot.positionSeconds,
            rate: snapshot.state == .playing ? snapshot.rate : 0
        )
    }

    /// 换 identity 或停止：丢弃布局表与时间线状态并清屏。
    private func resetTimelineState() {
        coordinator.reset()
        materializer.clear()
        latestSnapshot = nil
        reconciledPosition = nil
        discontinuityGeneration = nil
    }

    /// 把当前设置交给布局 coordinator；画面尚未布局（尺寸为 0）时不布局。
    private func updateLayoutParameters(debounced: Bool) {
        let configuration = DanmakuLaneConfiguration(
            surfaceWidth: surfaceWidth,
            surfaceHeight: surfaceHeight,
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
        coordinator.setParameters(parameters, debounced: debounced)
    }
}
