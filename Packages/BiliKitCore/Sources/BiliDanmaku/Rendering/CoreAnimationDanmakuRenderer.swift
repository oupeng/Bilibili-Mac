import AppKit
import BiliApplication
import BiliModels
import Foundation
import QuartzCore

/// Core Animation 弹幕 backend：纹理准备与按媒体时间安装的弹幕 layer。
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
/// 拥有 `rootLayer`、活动 layer、纹理准备 owner 与整屏重排时的交叉淡化（`DanmakuCrossfade`）。宿主
/// 把 `containerLayer` 挂进视图，再经 `mount(clockLayer:)` 把同步 layer 交给淡化容器，`rootLayer` 挂在
/// 同步 layer 下；内存压力监听由 App 窗口 adapter 持有。暂停时增删 layer 由系统照常合成，renderer 不需要主动请求重新合成。
@MainActor
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private struct Entry {
        let layer: CALayer
        var placement: DanmakuLanePlacement
        let textureByteCost: Int
        let textureKey: DanmakuTextureCacheKey
        let image: CGImage
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
    /// 弹幕 layer 与 `rootLayer` 上禁用的隐式动画：上屏、移除、子层与几何变化都不带过渡。
    ///
    /// 用 `actions` 逐个 layer 关掉，而不是给改动另包显式事务：顶层显式事务在 commit 时就单独提交，会把
    /// 同一次 reconcile 的增删拆进不同的提交；速率为 0 时移除的淡出过渡还会冻在第一帧。
    private static let disabledActions: [String: any CAAction] = [
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
        "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()
    ]

    public let rootLayer: CALayer
    /// 宿主挂进视图 layer 树的最外层容器；淡化在它下面、同步 layer 之外进行。
    public var containerLayer: CALayer { crossfade.containerLayer }
    private let crossfade: DanmakuCrossfade

    /// 媒体时间 0 对应的动画 `beginTime`，由宿主按同步 layer 的约定注入。
    private let beginTimeAtZero: CFTimeInterval

    /// 当前 surface 的 backing scale，已归一到 1...`maximumBackingScale`；变化时取消在途准备，
    /// 因为纹理按 scale 栅格化。
    private var backingScale: Double
    private var entries: [String: Entry] = [:]
    private var surfaceSize = CGSize.zero
    private let preparationOwner: DanmakuTexturePreparationOwner
    /// 已上屏 layer 的纹理字节合计，对照 `maximumActiveTextureByteCost`。
    private(set) var activeTextureByteCost = 0

    /// `beginTimeAtZero` 是媒体时间 0 对应的动画开始时间（App 传 `AVCoreAnimationBeginTimeAtZero`）；
    /// `crossfadeClock` 给交叉淡化计时收尾（App 传 `ContinuousClock`）。
    ///
    /// 初始 backing scale 取默认值；宿主挂上 surface 后经 `updateSurfaceSize` 换成窗口的实际值。
    public init(
        beginTimeAtZero: CFTimeInterval,
        crossfadeClock: any Clock<Duration>
    ) {
        self.beginTimeAtZero = beginTimeAtZero
        crossfade = DanmakuCrossfade(clock: crossfadeClock, disabledActions: Self.disabledActions)
        backingScale = DanmakuTextureRasterizer.defaultBackingScale
        preparationOwner = DanmakuTexturePreparationOwner()
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        // y 轴向下，与 allocator 自顶边计算的 `originY` 一致。
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
        rootLayer.actions = Self.disabledActions
    }

    /// 把宿主的同步 layer 挂进淡入容器，`rootLayer` 挂在同步 layer 下；宿主接管 surface 时调用。
    public func mount(clockLayer: CALayer) {
        crossfade.mount(clockLayer: clockLayer, contentLayer: rootLayer)
    }

    public func prepare(
        _ event: DanmakuEvent,
        preparationID: UInt64,
        completion:
            @escaping @MainActor @Sendable (
                DanmakuPreparationResult
            ) -> Void
    ) {
        preparationOwner.prepare(
            event: event,
            backingScale: backingScale,
            preparationID: preparationID,
            completion: completion
        )
    }

    @discardableResult
    public func install(
        _ placement: DanmakuLanePlacement,
        preparationID: UInt64,
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
                expectedKey: key
            ),
            let image = crossfade.reusableImage(for: event.id, key: key)
                ?? Self.makeImage(payload)
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
            textureByteCost: payload.byteCost,
            textureKey: key,
            image: image
        )
        activeTextureByteCost += payload.byteCost - replacedCost
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
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
    }

    public func clearAll() {
        preparationOwner.cancelAllPreparations()
        crossfade.finish()
        removeAllEntries()
    }

    public func beginCrossfade(at mediaTime: Double, rate: Double) {
        let layers = entries.map { eventID, entry in
            (eventID: eventID, layer: entry.layer, key: entry.textureKey, image: entry.image)
        }
        entries.removeAll(keepingCapacity: false)
        activeTextureByteCost = 0
        crossfade.begin(layers: layers, template: rootLayer, mediaTime: mediaTime, rate: rate)
    }

    public func startCrossfade() {
        crossfade.start()
    }

    public func finishCrossfade() {
        crossfade.finish()
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
        crossfade.setFrame(CGRect(origin: .zero, size: surfaceSize))
        rootLayer.frame = CGRect(origin: .zero, size: surfaceSize)
        for entry in entries.values {
            updateFixedGeometry(
                for: entry,
                heightDelta: surfaceSize.height - oldSurfaceSize.height
            )
        }
        CATransaction.commit()
    }

    /// 会话结束：取消在途准备并清屏。
    public func stop() {
        preparationOwner.cancelAllPreparations()
        crossfade.finish()
        removeAllEntries()
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
    /// 只在尺寸变化到按新尺寸重新布局（去抖之后交叉淡化成新布局）之间起作用。
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
