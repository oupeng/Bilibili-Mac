import AppKit
import BiliApplication
import BiliModels
import Foundation
import QuartzCore

/// 有硬上限的 Core Animation 弹幕 backend，负责纹理准备、layer identity、动画时钟与回收。
///
/// Core Text shaping、整行 union mask、vImage 阴影与 RGBA 合成都由有界 preparation owner
/// 在后台完成。MainActor 只消费不可变像素并安装一个普通 `CALayer`；用户透明度统一落在
/// `rootLayer.opacity`，活动 layer 不启用实时 shadow。
///
/// 用 Core Animation 而不用 SwiftUI：每条弹幕是一个由渲染服务器插值的 layer 动画，暂停与倍速只改
/// `rootLayer` 的时间，不需要逐帧驱动（见 docs/ARCHITECTURE.md「弹幕」）。拥有 `rootLayer`、活动
/// layer 与纹理准备 owner；`rootLayer` 挂到哪个视图由 App 的 overlay 决定，内存压力监听由 App 窗口
/// adapter 持有。`clearAll` 与 `stop` 先递增 `renderEpoch` 再取消准备、移除 layer，
/// 移除触发的迟到动画回调因此失效。
///
/// 静止时的重新合成：暂停、缓冲时视频不出新帧、`rootLayer.speed` 为 0，渲染服务器不再主动出帧；提交后
/// 屏上那块区域若没有完整重新合成，旧画面会一直留着，表现为错开几 pt 的两份弹幕，直到别的界面事件触发
/// 重绘。呈现控制器在一整批改动结束后调用 `recompositeIfStill`：静止且这批确实改动了 layer 树时，经宿主
/// 的 `frameScheduler`（App overlay 按需建立的 display link）在下一帧对 `rootLayer` 做一次无视觉变化的
/// 属性写入。请求挂 `frameRequestTimeout` 兜底，到点没回调就放弃并让宿主释放 display link；`stop` 取消
/// 在途请求。
@MainActor
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private struct Entry {
        let layer: CALayer
        let placement: DanmakuLanePlacement
        let textureByteCost: Int
        let objectIdentity: UInt64
        let relay: AnimationCompletionRelay
    }

    /// 已上屏 layer 的纹理字节总上限；超出时新弹幕不上屏，呈现控制器归还它占用的车道。
    ///
    /// 与活动数硬上限一起限定最坏情况的纹理内存：调大允许更多长文本同屏，调小则高峰期更早丢弃。
    static let maximumActiveTextureByteCost = 64 * 1_024 * 1_024
    /// 每个弹幕 layer 上唯一的位移／停留动画的 key。
    static let animationKey = "danmaku"
    /// 下一帧请求的兜底时限：到点还没回调就放弃这次重新合成，并让宿主释放 display link。
    ///
    /// 60～120Hz 下下一帧在 17ms 内到达；显示器休眠等情况下 display link 可能一直不回调，没有时限请求会
    /// 永远挂着。调小会在卡顿时提前放弃，调大则 display link 在不出帧时多占一会儿。
    static let frameRequestTimeout = Duration.milliseconds(100)
    /// 弹幕 layer 与 `rootLayer` 上禁用的隐式动画：上屏、移除与子层变化都不带过渡。
    ///
    /// 用 `actions` 逐个 layer 关掉，而不是给清屏与移除另包显式事务：顶层显式事务在 commit 时就单独
    /// 提交，会把同一轮的清屏与补位上屏拆开；速率为 0 时移除的淡出过渡还会冻在第一帧。上屏的
    /// `renderPrepared` 仍包一个只为关闭 position 等属性动作的显式事务：本轮已有隐式事务（例如清屏
    /// 刚移除过 layer）时它嵌套其中、随本轮一起提交，屏上原本为空时它可能单独提交。
    private static let disabledActions: [String: any CAAction] = [
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull()
    ]

    public weak var delegate: (any DanmakuRenderingBackendDelegate)?
    public let rootLayer: CALayer
    /// 提供下一显示帧回调的宿主。
    ///
    /// 由 App 的弹幕 overlay 在接管 surface 时设置、交还时清空；弱引用，overlay 持有 renderer。
    public weak var frameScheduler: (any DanmakuFrameScheduling)?

    /// 是否有还没重新合成的改动（上屏、移除、清屏或速率变化）。
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

    /// `clearAll` 与 `stop` 时递增；随动画回调携带，`completeAnimation` 比对不等就丢弃该回调，
    /// 清屏前的迟到回调因此不会移除清屏后的新 layer，也不会回报给控制器。
    private var renderEpoch: UInt64 = 0

    /// 当前 surface 的 backing scale，已归一到 1...`maximumBackingScale`；变化时取消在途准备，
    /// 因为纹理按 scale 栅格化。
    private var backingScale: Double
    private var entries: [String: Entry] = [:]
    /// 每安装一个 layer 递增；同一事件 ID 被移除后再次上屏时，旧 layer 的迟到回调因 identity
    /// 不等而被丢弃。
    private var nextObjectIdentity: UInt64 = 0
    private var surfaceSize = CGSize.zero
    private let preparationOwner: DanmakuTexturePreparationOwner
    /// 已上屏 layer 的纹理字节合计，对照 `maximumActiveTextureByteCost`。
    private(set) var activeTextureByteCost = 0

    /// 初始 backing scale 取默认值；宿主挂上 surface 后经 `updateSurfaceSize` 换成窗口的实际值。
    public init() {
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
        backingScale: Double,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        let normalizedScale = DanmakuTextureRasterizer.normalizedBackingScale(backingScale)
        guard normalizedScale == self.backingScale else {
            completion(.rejected(.cancelled))
            return
        }
        preparationOwner.prepare(
            event: event,
            backingScale: normalizedScale,
            preparationID: preparationID,
            generation: generation,
            completion: completion
        )
    }

    @discardableResult
    public func renderPrepared(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
        generation: UInt64,
        elapsedSeconds: Double
    ) -> Bool {
        let event = placement.request.event
        guard entries[event.id] == nil,
            entries.count
                < DanmakuLaneConfiguration.hardMaximumActiveCount,
            surfaceSize.width > 0,
            surfaceSize.height > 0,
            let key = DanmakuTextureRasterizer.key(
                event: event,
                backingScale: backingScale
            ),
            let payload = preparationOwner.consume(
                preparationID: preparationID,
                generation: generation,
                expectedKey: key
            )
        else {
            preparationOwner.discard(preparationID: preparationID)
            return false
        }
        let remainingTextureBytes = max(
            Self.maximumActiveTextureByteCost - activeTextureByteCost,
            0
        )
        guard payload.byteCost <= remainingTextureBytes,
            let image = Self.makeImage(payload)
        else {
            return false
        }

        nextObjectIdentity &+= 1
        let objectIdentity = nextObjectIdentity
        let layer = makeLayer(for: placement, image: image, scale: backingScale)
        let relay = AnimationCompletionRelay(
            renderer: self,
            eventID: event.id,
            objectIdentity: objectIdentity,
            renderEpoch: renderEpoch
        )
        let animation = makeAnimation(for: placement, layer: layer)
        animation.delegate = relay
        entries[event.id] = Entry(
            layer: layer,
            placement: placement,
            textureByteCost: payload.byteCost,
            objectIdentity: objectIdentity,
            relay: relay
        )
        activeTextureByteCost += payload.byteCost

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.addSublayer(layer)
        // 模型值直接设为终点：动画结束到 layer 被异步移除之间，layer 停在画面外，不会闪回起点。
        if event.mode == .scrolling {
            layer.position.x = -layer.bounds.width / 2
        }
        // 补位：把开始时间移到过去，动画从已经走过的位置继续，并在剩余时长后结束。时间换算经过
        // rootLayer，暂停与倍速调整的是 rootLayer 的时间，补位弹幕随之一起停走。
        if elapsedSeconds > 0, elapsedSeconds.isFinite {
            animation.beginTime =
                layer.convertTime(CACurrentMediaTime(), from: nil) - elapsedSeconds
        }
        layer.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
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
        removeEntry(eventID: eventID)
    }

    public func clearAll() {
        advanceEpoch()
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
    }

    /// 在保持当前 layer 局部时间连续的前提下暂停或调整动画速率；立即按此刻生效。
    public func setPlaybackRate(_ rate: Double) {
        let newRate = rate.isFinite ? max(rate, 0) : 0
        guard Double(rootLayer.speed) != newRate else { return }
        hasChangesSinceRecomposite = true
        let mediaTime = CACurrentMediaTime()
        let parentTime =
            rootLayer.superlayer?
            .convertTime(mediaTime, from: nil)
            ?? mediaTime
        let localTime = rootLayer.convertTime(mediaTime, from: nil)
        // 局部时间按 (父时间 − beginTime) × speed + timeOffset 换算，只改 speed 会让局部时间跳变；
        // 先以此刻为 beginTime、以当前局部时间为 timeOffset，再改 speed，动画从原位置按新速率继续。
        rootLayer.beginTime = parentTime
        rootLayer.timeOffset = localTime
        rootLayer.speed = Float(newRate)
    }

    /// 一整批改动结束后由呈现控制器调用一次；静止且这批改动了 layer 树时请求下一帧重新合成。
    ///
    /// 同一轮或下一帧之前的多次调用合并为一次请求；不静止或没有可用的显示帧时不请求。
    /// 宿主从不可见恢复可见时也调用它，补上不可见期间没能完成的重新合成。
    public func recompositeIfStill() {
        guard hasChangesSinceRecomposite else { return }
        guard rootLayer.speed == 0, !isFrameRequested else {
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
        guard rootLayer.speed == 0 else { return }
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
        let normalizedScale = DanmakuTextureRasterizer.normalizedBackingScale(backingScale)
        if normalizedScale != self.backingScale {
            self.backingScale = normalizedScale
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

    /// 会话结束：清屏、速率归零，并取消在途的帧请求，display link 随之停止。
    public func stop() {
        advanceEpoch()
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
        setPlaybackRate(0)
        hasChangesSinceRecomposite = false
        cancelFrameRequests()
    }

    /// 由 `AnimationCompletionRelay` 在 MainActor 调用；epoch 与 object identity 都匹配时才移除
    /// layer 并通知 delegate。
    func completeAnimation(
        eventID: String,
        objectIdentity: UInt64,
        renderEpoch completionEpoch: UInt64
    ) {
        guard completionEpoch == renderEpoch,
            let entry = entries[eventID],
            entry.objectIdentity == objectIdentity
        else {
            return
        }
        removeEntry(eventID: eventID)
        delegate?.rendererDidFinish(eventID: eventID)
    }

    private func makeLayer(
        for placement: DanmakuLanePlacement,
        image: CGImage,
        scale: Double
    ) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsScale = CGFloat(scale)
        layer.contentsGravity = .resize
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.bounds = CGRect(
            x: 0,
            y: 0,
            width: placement.request.width,
            height: placement.request.height
        )
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(
            x: placement.request.event.mode == .scrolling
                ? surfaceSize.width + layer.bounds.width / 2
                : surfaceSize.width / 2,
            y: placement.originY + layer.bounds.height / 2
        )
        layer.shadowOpacity = 0
        layer.actions = Self.disabledActions
        return layer
    }

    private func makeAnimation(
        for placement: DanmakuLanePlacement,
        layer: CALayer
    ) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch placement.request.event.mode {
        case .scrolling:
            animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = layer.position.x
            animation.toValue = -layer.bounds.width / 2
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .top, .bottom:
            // 顶部与底部弹幕不移动，用一个不改变外观的 opacity 动画计时，结束时同样经 delegate
            // 回收。
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
        }
        animation.duration = placement.request.durationSeconds
        return animation
    }

    /// 顶部与底部弹幕随新宽度重新居中，底部弹幕随高度变化平移以贴住底边；滚动弹幕保持入场时的运动。
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

    private func advanceEpoch() {
        renderEpoch &+= 1
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

    private func removeEntry(eventID: String) {
        guard let entry = entries.removeValue(forKey: eventID) else {
            return
        }
        activeTextureByteCost -= entry.textureByteCost
        hasChangesSinceRecomposite = true
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
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
