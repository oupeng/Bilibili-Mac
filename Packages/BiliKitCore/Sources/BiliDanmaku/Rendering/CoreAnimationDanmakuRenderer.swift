import AppKit
import BiliApplication
import BiliModels
import Foundation
import QuartzCore

/// Core Animation 弹幕 backend：纹理准备、按媒体时间安装的弹幕 layer 与静止时的重新合成。
///
/// Core Text shaping、整行 union mask、vImage 阴影与 RGBA 合成都由有界 preparation owner
/// 在后台完成。MainActor 只消费不可变像素并安装一个普通 `CALayer`；用户透明度统一落在
/// `rootLayer.opacity`，活动 layer 不启用实时 shadow。
///
/// 用 Core Animation 而不用 SwiftUI：每条弹幕是一个由渲染服务器插值的 layer 动画，不需要逐帧驱动（见
/// docs/ARCHITECTURE.md「弹幕」）。`rootLayer` 由 App 挂在跟随播放 item 时间的同步 layer 下，这里的
/// 局部时间就是媒体时间：动画的 `beginTime` 是弹幕自己的时间点，暂停、倍速、seek 与缓冲停顿都由同步
/// layer 处理，renderer 不维护时钟。时间点 0 不能直接写 0（Core Animation 会当作「现在」），用宿主
/// 注入的 `beginTimeAtZero`。动画 `removedOnCompletion` 为 false、fillMode 保持默认：动画区间之外
/// 呈现回到模型值，所以模型值本身不可见（滚动弹幕停在画面左外侧，顶部底部弹幕不透明度为 0），
/// 区间之内由动画撑起。layer 何时移除由 `DanmakuMaterializer` 按媒体时间决定，renderer 不监听动画结束。
///
/// 拥有 `rootLayer`、活动 layer 与纹理准备 owner；`rootLayer` 挂到哪里由 App 的 overlay 决定，内存压力
/// 监听由 App 窗口 adapter 持有。
///
/// 静止时的重新合成：暂停、缓冲时视频不出新帧，同步 layer 的速率为 0，渲染服务器不再主动出帧；提交后
/// 屏上那块区域若没有完整重新合成，旧画面会一直留着，表现为错开几 pt 的两份弹幕，直到别的界面事件触发
/// 重绘。呈现端在一整批改动结束后调用 `recompositeIfStill`：静止（`setStill`）且这批确实改动了 layer
/// 树时，经宿主的 `frameScheduler`（App overlay 按需建立的 display link）在下一帧对 `rootLayer` 做一次
/// 无视觉变化的属性写入。请求挂 `frameRequestTimeout` 兜底，到点没回调就放弃并让宿主释放 display link；
/// `stop` 取消在途请求。
@MainActor
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private struct Entry {
        let layer: CALayer
        var placement: DanmakuLanePlacement
        let textureByteCost: Int
    }

    /// 已上屏 layer（含已挂上、还没进场的前瞻弹幕）的纹理字节总上限；超出时按 `makeRoom` 的顺序腾地方，
    /// 腾不出来的新弹幕不上屏。
    ///
    /// 只作内存安全阀：同屏数量由布局阶段的 `hardMaximumActiveCount` 决定，这里拒绝的弹幕不归还车道，
    /// 车道布局因此不受它影响。按全部 layer 计算而不是只算已进场的：前瞻弹幕也占着同样的内存；但已进场的
    /// 弹幕可以挤掉前瞻弹幕，效果上与只算已进场弹幕时一样优先保证屏上可见的。调大允许更多长文本同屏，
    /// 调小则高峰期更早缺席。
    static let maximumActiveTextureByteCost = 64 * 1_024 * 1_024
    /// 每个弹幕 layer 上唯一的位移／显隐动画的 key。
    static let animationKey = "danmaku"
    /// 下一帧请求的兜底时限：到点还没回调就放弃这次重新合成，并让宿主释放 display link。
    ///
    /// 60～120Hz 下下一帧在 17ms 内到达；显示器休眠等情况下 display link 可能一直不回调，没有时限请求会
    /// 永远挂着。调小会在卡顿时提前放弃，调大则 display link 在不出帧时多占一会儿。
    static let frameRequestTimeout = Duration.milliseconds(100)
    /// 弹幕 layer 与 `rootLayer` 上禁用的隐式动画：上屏、移除、子层与几何变化都不带过渡。
    ///
    /// 用 `actions` 逐个 layer 关掉，而不是给改动另包显式事务：顶层显式事务在 commit 时就单独提交，会把
    /// 同一次 reconcile 的增删拆进不同的提交；速率为 0 时移除的淡出过渡还会冻在第一帧。
    private static let disabledActions: [String: any CAAction] = [
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
        "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()
    ]

    public let rootLayer: CALayer
    /// 提供下一显示帧回调的宿主。
    ///
    /// 由 App 的弹幕 overlay 在接管 surface 时设置、交还时清空；弱引用，overlay 持有 renderer。
    public weak var frameScheduler: (any DanmakuFrameScheduling)?

    /// 媒体时间 0 对应的动画 `beginTime`，由宿主按同步 layer 的约定注入。
    private let beginTimeAtZero: CFTimeInterval
    /// 画面此刻是否静止（暂停、缓冲、未播放）；由呈现控制器按时间线快照设置，还没有快照时按走动处理。
    private var isStill = false
    /// 是否有还没重新合成的改动（上屏、更新、移除或清屏）。
    ///
    /// 请求被宿主接受时清除；被拒绝（不可见）、以 false 回调（没出帧就停了）或超时放弃时恢复，宿主恢复
    /// 可见后再调用 `recompositeIfStill` 补上。走动中直接清除：渲染服务器本来就在出帧。
    private var hasChangesSinceRecomposite = false
    /// 是否有已被宿主接受、尚未回调的帧请求；同一时刻最多一个，期间的改动合并进它。
    private var isFrameRequested = false
    /// 每次请求帧与取消时递增；回调与兜底带上请求时的值，不等就丢弃。
    private var frameRequestGeneration: UInt64 = 0
    /// 重新合成时在两个值之间切换的标记，保证每次都是一次真实的属性变化。
    private var recompositeMarker = false

    /// 当前 surface 的 backing scale，已归一到 1...`maximumBackingScale`；变化时取消在途准备，
    /// 因为纹理按 scale 栅格化。
    private var backingScale: Double
    private var entries: [String: Entry] = [:]
    private var surfaceSize = CGSize.zero
    private let preparationOwner: DanmakuTexturePreparationOwner
    /// 已上屏 layer 的纹理字节合计，对照 `maximumActiveTextureByteCost`。
    private(set) var activeTextureByteCost = 0

    /// `beginTimeAtZero` 是媒体时间 0 对应的动画开始时间（App 传 `AVCoreAnimationBeginTimeAtZero`）。
    ///
    /// 初始 backing scale 取默认值；宿主挂上 surface 后经 `updateSurfaceSize` 换成窗口的实际值。
    public init(beginTimeAtZero: CFTimeInterval) {
        self.beginTimeAtZero = beginTimeAtZero
        backingScale = DanmakuTextureRasterizer.defaultBackingScale
        preparationOwner = DanmakuTexturePreparationOwner()
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        // y 轴向下，与 allocator 自顶边计算的 `originY` 一致。
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
        rootLayer.actions = Self.disabledActions
    }

    public func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        generation: UInt64,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationOwner.prepare(
            event: event,
            backingScale: backingScale,
            preparationID: preparationID,
            generation: generation,
            completion: completion
        )
    }

    @discardableResult
    public func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        at position: Double
    ) -> DanmakuInstallResult {
        let event = placement.request.event
        guard surfaceSize.width > 0,
            surfaceSize.height > 0,
            let key = DanmakuTextureRasterizer.key(
                event: event,
                backingScale: backingScale
            ),
            let payload = preparationOwner.consume(
                preparationID: preparationID,
                generation: generation,
                expectedKey: key
            ),
            let image = Self.makeImage(payload)
        else {
            preparationOwner.discard(preparationID: preparationID)
            return .notInstalled
        }
        let replacedCost = entries[event.id]?.textureByteCost ?? 0
        let evicted = makeRoom(
            for: payload.byteCost - replacedCost,
            admitting: placement,
            at: position
        )
        let remainingTextureBytes =
            Self.maximumActiveTextureByteCost - activeTextureByteCost + replacedCost
        guard payload.byteCost <= remainingTextureBytes else {
            return DanmakuInstallResult(isInstalled: false, evictedEventIDs: evicted)
        }

        // 已在屏（窗口换到另一块屏幕后纹理要按新 scale 重建）时原位换纹理，不先移除，画面不缺这一条。
        let layer = entries[event.id]?.layer ?? CALayer()
        layer.contents = image
        layer.contentsScale = CGFloat(backingScale)
        if entries[event.id] == nil {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.shadowOpacity = 0
            layer.actions = Self.disabledActions
            rootLayer.addSublayer(layer)
        }
        configure(layer, for: placement)
        entries[event.id] = Entry(
            layer: layer,
            placement: placement,
            textureByteCost: payload.byteCost
        )
        activeTextureByteCost += payload.byteCost - replacedCost
        hasChangesSinceRecomposite = true
        return DanmakuInstallResult(isInstalled: true, evictedEventIDs: evicted)
    }

    /// 纹理字节不够装下 `placement` 时腾出空间，返回被移除的弹幕 ID。
    ///
    /// 先移除已经走完的（`position` 时已过期、只是还没等到下一次 reconcile），再移除还没进场的前瞻弹幕
    /// （进场最晚的先移除）；只有已进场的弹幕才能挤掉前瞻弹幕，前瞻弹幕之间不互相挤占。已进场、还在走的
    /// 弹幕从不移除，所以已进场的弹幕先挂上的优先，超出时被拒绝的总是前瞻弹幕或更晚的那条。
    private func makeRoom(
        for additionalBytes: Int,
        admitting placement: DanmakuLanePlacement,
        at position: Double
    ) -> [String] {
        var evicted: [String] = []
        guard additionalBytes > Self.maximumActiveTextureByteCost - activeTextureByteCost else {
            return evicted
        }
        let admittingID = placement.request.event.id
        let others = entries.values.map(\.placement).filter {
            $0.request.event.id != admittingID
        }
        let finished = others.filter { $0.expiresAtSeconds <= position }
            .sorted { $0.request.event.id < $1.request.event.id }
        var lookahead: [DanmakuLanePlacement] = []
        if placement.admittedAtSeconds <= position {
            lookahead = others.filter { $0.admittedAtSeconds > position }
            // 进场更晚的先挤掉。
            lookahead.sort { DanmakuLanePlacement.precedes($1, $0) }
        }
        for candidate in finished + lookahead
        where additionalBytes > Self.maximumActiveTextureByteCost - activeTextureByteCost {
            let eventID = candidate.request.event.id
            remove(eventID: eventID)
            evicted.append(eventID)
        }
        return evicted
    }

    @discardableResult
    public func update(_ placement: DanmakuLanePlacement) -> Bool {
        let eventID = placement.request.event.id
        guard var entry = entries[eventID] else { return false }
        guard entry.placement != placement else { return true }
        entry.placement = placement
        entries[eventID] = entry
        configure(entry.layer, for: placement)
        hasChangesSinceRecomposite = true
        return true
    }

    public func discardPreparation(preparationID: UInt64) {
        preparationOwner.discard(preparationID: preparationID)
    }

    public func cancelPendingPreparations() {
        preparationOwner.cancelAllPreparations()
    }

    /// 系统内存压力的响应：清空纹理缓存与已准备未上屏的纹理，在途准备以 `.capacity` 拒绝；
    /// 已上屏的 layer 不受影响。
    ///
    /// 由 App 组装层持有的内存压力监听在主线程调用。renderer 刻意不自己安装进程级
    /// DispatchSource：系统事件会同时打到进程内每个实例，监听的取消点应跟随 App 的窗口生命周期。
    public func handleMemoryPressure() {
        preparationOwner.handleMemoryPressure()
    }

    public func remove(eventID: String) {
        guard let entry = entries.removeValue(forKey: eventID) else {
            return
        }
        activeTextureByteCost -= entry.textureByteCost
        hasChangesSinceRecomposite = true
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
    }

    public func clearAll() {
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
    }

    /// 只记下状态，不算一次改动：停下与走动改变的是同步 layer 的速率，弹幕 layer 树本身没变。
    public func setStill(_ still: Bool) {
        isStill = still
    }

    /// 一整批改动结束后由呈现端调用一次；静止且这批改动了 layer 树时请求下一帧重新合成。
    ///
    /// 同一轮或下一帧之前的多次调用合并为一次请求；不静止或没有可用的显示帧时不请求。
    /// 宿主从不可见恢复可见时也调用它，补上不可见期间没能完成的重新合成。
    public func recompositeIfStill() {
        guard hasChangesSinceRecomposite else { return }
        guard isStill, !isFrameRequested else {
            // 走动中不需要；已有请求在途时这批改动随它一起合成。
            hasChangesSinceRecomposite = false
            return
        }
        guard let frameScheduler else { return }
        frameRequestGeneration &+= 1
        let generation = frameRequestGeneration
        isFrameRequested = frameScheduler.requestNextFrame { [weak self] didDisplay in
            self?.frameDidArrive(didDisplay: didDisplay, generation: generation)
        }
        guard isFrameRequested else { return }
        hasChangesSinceRecomposite = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.frameRequestTimeout)
            self?.frameRequestTimedOut(generation: generation)
        }
    }

    /// 下一帧到了：仍静止时在显式事务里切换一次透明背景（nil 与透明色之间），让窗口重新合成这块区域。
    ///
    /// 不用 `setNeedsDisplay`：`rootLayer` 没有 delegate，`display` 会为整个 surface 建一块空白 backing
    /// store，既占内存又多一层全幅混合。不调用 `flush`：这次写入随 display link 回调所在的这一轮提交。
    private func frameDidArrive(didDisplay: Bool, generation: UInt64) {
        guard generation == frameRequestGeneration, isFrameRequested else { return }
        isFrameRequested = false
        guard isStill else { return }
        guard didDisplay else {
            hasChangesSinceRecomposite = true
            return
        }
        recompositeMarker.toggle()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.backgroundColor = recompositeMarker ? CGColor.clear : nil
        CATransaction.commit()
    }

    private func frameRequestTimedOut(generation: UInt64) {
        guard generation == frameRequestGeneration, isFrameRequested else { return }
        cancelFrameRequests()
        hasChangesSinceRecomposite = true
    }

    /// 放弃在途的帧请求并让宿主停止 display link；宿主以 `false` 回调时因 generation 不等而被丢弃。
    private func cancelFrameRequests() {
        frameRequestGeneration &+= 1
        isFrameRequested = false
        frameScheduler?.cancelNextFrameRequests()
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.opacity = Float(opacity.value)
        CATransaction.commit()
    }

    public func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        if backingScale != self.backingScale {
            self.backingScale = backingScale
            preparationOwner.cancelAllPreparations()
        }
        let oldSurfaceSize = surfaceSize
        surfaceSize = CGSize(
            width: max(width.isFinite ? width : 0, 0),
            height: max(height.isFinite ? height : 0, 0)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.frame = CGRect(origin: .zero, size: surfaceSize)
        for entry in entries.values {
            updateFixedGeometry(
                for: entry,
                heightDelta: surfaceSize.height - oldSurfaceSize.height
            )
        }
        CATransaction.commit()
    }

    /// 会话结束：清屏，并取消在途的帧请求，display link 随之停止。
    public func stop() {
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
        isStill = false
        hasChangesSinceRecomposite = false
        cancelFrameRequests()
    }

    /// 媒体时间换算成同步 layer 下的动画开始时间；0 写成 `beginTimeAtZero`，否则会被当作「现在」。
    func animationBeginTime(forMediaTime seconds: Double) -> CFTimeInterval {
        seconds > 0 ? seconds : beginTimeAtZero
    }

    /// 按 placement 设定 layer 的几何、不可见的模型值与唯一的动画；安装与布局替换共用。
    private func configure(_ layer: CALayer, for placement: DanmakuLanePlacement) {
        let request = placement.request
        let width = request.width
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: request.height)
        let centerY = placement.originY + request.height / 2
        let animation: CABasicAnimation
        switch request.event.mode {
        case .scrolling:
            // 模型值在画面左外侧：动画开始之前与结束之后都看不见。
            layer.position = CGPoint(x: -width / 2, y: centerY)
            layer.opacity = 1
            animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = placement.surfaceWidthAtAdmission + width / 2
            animation.toValue = -width / 2
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .top, .bottom:
            // 模型不透明度为 0，停留期间由不透明度为 1 的动画撑起。
            layer.position = CGPoint(x: surfaceSize.width / 2, y: centerY)
            layer.opacity = 0
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
        }
        animation.beginTime = animationBeginTime(forMediaTime: placement.admittedAtSeconds)
        animation.duration = request.durationSeconds
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
    }

    /// 顶部与底部弹幕随新宽度重新居中，底部弹幕随高度变化平移以贴住底边；滚动弹幕保持布局时的运动。
    ///
    /// 只在尺寸变化到按新尺寸重新布局之间起作用，重新布局后整屏换成新布局。
    private func updateFixedGeometry(
        for entry: Entry,
        heightDelta: CGFloat
    ) {
        switch entry.placement.request.event.mode {
        case .scrolling:
            return
        case .top:
            entry.layer.position.x = surfaceSize.width / 2
        case .bottom:
            entry.layer.position.x = surfaceSize.width / 2
            entry.layer.position.y += heightDelta
        }
    }

    private func removeAllEntries() {
        let oldEntries = entries
        entries.removeAll(keepingCapacity: false)
        activeTextureByteCost = 0
        if !oldEntries.isEmpty {
            hasChangesSinceRecomposite = true
        }
        for entry in oldEntries.values {
            entry.layer.removeAllAnimations()
            entry.layer.removeFromSuperlayer()
        }
    }

    private static func makeImage(
        _ payload: DanmakuTexturePayload
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: payload.pixels as CFData)
        else {
            return nil
        }
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        ).union(.byteOrder32Big)
        return CGImage(
            width: payload.widthPixels,
            height: payload.heightPixels,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: payload.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
