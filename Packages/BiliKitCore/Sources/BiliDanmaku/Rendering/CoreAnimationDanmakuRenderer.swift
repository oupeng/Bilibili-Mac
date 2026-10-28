import AppKit
import BiliApplication
import BiliModels
import Foundation
import QuartzCore

/// Core Animation 弹幕 backend：纹理准备与按媒体时间挂上的弹幕 layer。
///
/// Core Text shaping、整行 union mask、vImage 阴影与 RGBA 合成都由有界 preparation owner
/// 在后台完成并包成 `CGImage`。MainActor 只把它设为一个普通 `CALayer` 的 contents；用户透明度统一落在
/// `rootLayer.opacity`，活动 layer 不启用实时 shadow。
///
/// 用 Core Animation 而不用 SwiftUI：每条弹幕是一个由渲染服务器插值的 layer 动画，不需要逐帧驱动（见
/// docs/ARCHITECTURE.md「弹幕」）。`rootLayer` 由 App 挂在跟随播放 item timebase 的时钟层下，这里的
/// 局部时间就是媒体时间：动画的 `beginTime` 是弹幕自己的时间点，暂停、倍速、seek 与缓冲停顿都由时钟层
/// 处理，renderer 不维护时钟。时间点 0 不能直接写 0（Core Animation 会当作「现在」），用宿主
/// 注入的 `beginTimeAtMediaZero`。动画 `removedOnCompletion` 为 false、fillMode 保持默认：动画区间之外
/// 呈现回到模型值，所以模型值本身不可见（滚动弹幕停在规划画布左外侧，顶部底部弹幕不透明度为 0），
/// 区间之内由动画撑起。layer 何时移除由 `DanmakuMaterializer` 按媒体时间决定，renderer 不监听动画结束。
///
/// 取景框：弹幕按规划画布布局，窗口只决定露出哪一部分（见 docs/ARCHITECTURE.md「弹幕」）。弹幕 layer
/// 不直接挂在 `rootLayer` 下，而是挂在三个零尺寸的锚点层下：滚动弹幕锚在窗口右边缘、顶部弹幕锚在顶边
/// 中点、底部弹幕锚在底边中点。弹幕在锚点局部坐标里的轨迹只由 placement 决定，窗口尺寸变化时只移动
/// 锚点，不改任何弹幕的动画；超出窗口的部分由 `rootLayer` 裁掉。
///
/// 拥有 `rootLayer`、三个锚点层、活动 layer 与纹理准备 owner；`rootLayer` 挂到哪里由 App 的 overlay 决定，内存压力
/// 监听由 App 窗口 adapter 持有。暂停时增删 layer 由系统照常合成，renderer 不需要主动请求重新合成。
@MainActor
public final class CoreAnimationDanmakuRenderer:
    DanmakuRenderingBackend
{
    private struct Entry {
        let layer: CALayer
        var placement: DanmakuLanePlacement
        let textureByteCost: Int
    }

    /// 在屏 layer（含已挂上、还没进场的前瞻弹幕）的纹理字节总上限；超出时按 `makeRoom` 的顺序腾地方，
    /// 腾不出来的新弹幕不挂上。
    ///
    /// 只作内存安全阀：同屏数量由布局阶段的 `hardMaximumActiveCount` 决定，这里拒绝的弹幕不归还车道，
    /// 车道布局因此不受它影响。按全部 layer 计算而不是只算已进场的：前瞻弹幕也占着同样的内存；但已进场的
    /// 弹幕可以挤掉前瞻弹幕，效果上与只算已进场弹幕时一样优先保证屏上可见的。调大允许更多长文本同屏，
    /// 调小则高峰期更早缺席。
    ///
    /// 按 layer 计、不按 `CGImage` 去重：同一纹理挂在多个 layer 上时重复计入，是保守高估；另一方面每个
    /// 渲染过的 `CGImage` 在 Core Animation 侧另有一份像素拷贝，实际驻留接近计数的两倍。
    static let maximumActiveTextureByteCost = 64 * 1_024 * 1_024
    /// 每个弹幕 layer 上唯一的位移／显隐动画的 key。
    static let animationKey = "danmaku"
    /// 弹幕 layer、锚点层、`rootLayer` 与计数胶囊上禁用的隐式动画：挂上、移除、子层与几何变化都不带过渡。
    ///
    /// 用 `actions` 逐个 layer 关掉，而不是给改动另包显式事务：顶层显式事务在 commit 时就单独提交，会把
    /// 同一次 reconcile 的增删拆进不同的提交；速率为 0 时移除的淡出过渡还会冻在第一帧。
    static let disabledActions: [String: any CAAction] = [
        "onOrderIn": NSNull(), "onOrderOut": NSNull(), "sublayers": NSNull(),
        "position": NSNull(), "bounds": NSNull(), "opacity": NSNull()
    ]

    public let rootLayer: CALayer
    /// 滚动弹幕的锚点：位于窗口右边缘、顶边。
    private let scrollingAnchor = CALayer()
    /// 顶部弹幕的锚点：位于顶边中点。
    private let topAnchor = CALayer()
    /// 底部弹幕的锚点：位于底边中点。
    private let bottomAnchor = CALayer()

    /// 媒体时间 0 对应的动画 `beginTime`，由宿主按时钟层的约定注入。
    private let beginTimeAtMediaZero: CFTimeInterval

    /// 当前 surface 的 backing scale，已归一到 1...`maximumBackingScale`；变化时取消在途准备，
    /// 因为纹理按 scale 栅格化。
    private var backingScale: Double
    private var entries: [String: Entry] = [:]
    private var surfaceSize = CGSize.zero
    private let preparationOwner: DanmakuTexturePreparationOwner
    /// 合并弹幕的计数胶囊与它的字形图缓存。
    private let countBadgeLayers = DanmakuCountBadgeLayers()
    /// 互动弹幕卡片；容器层挂在所有弹幕之上。
    private let commandCardLayers: DanmakuCommandCardLayers
    /// 在屏 layer 的纹理字节合计，对照 `maximumActiveTextureByteCost`；每个 layer 计一次纹理的
    /// `byteCost`，共用同一 `CGImage` 的 layer 也各计一次，Core Animation 侧的拷贝不计入。
    private(set) var activeTextureByteCost = 0

    /// `beginTimeAtMediaZero` 是媒体时间 0 对应的动画开始时间（App 传时钟层定义的哨兵）。
    ///
    /// 初始 backing scale 取默认值；宿主挂上 surface 后经 `updateSurfaceSize` 换成窗口的实际值。
    public init(beginTimeAtMediaZero: CFTimeInterval) {
        self.beginTimeAtMediaZero = beginTimeAtMediaZero
        backingScale = DanmakuTextureRasterizer.defaultBackingScale
        preparationOwner = DanmakuTexturePreparationOwner()
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        // y 轴向下：锚点层与弹幕 layer 继承这个方向，滚动与顶部弹幕的车道自顶边往下数。
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
        rootLayer.actions = Self.disabledActions
        for anchor in [scrollingAnchor, topAnchor, bottomAnchor] {
            // 零尺寸：局部坐标原点就是 position，子层不被锚点自身裁剪。
            anchor.bounds = .zero
            anchor.actions = Self.disabledActions
            rootLayer.addSublayer(anchor)
        }
        commandCardLayers = DanmakuCommandCardLayers(
            backingScale: DanmakuTextureRasterizer.defaultBackingScale
        ) { seconds in
            Self.animationBeginTime(forMediaTime: seconds, mediaZero: beginTimeAtMediaZero)
        }
        rootLayer.addSublayer(commandCardLayers.containerLayer)
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
            )
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
        layer.contents = payload.image
        layer.contentsScale = CGFloat(backingScale)
        if entries[event.id] == nil {
            layer.contentsGravity = .resize
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.shadowOpacity = 0
            layer.actions = Self.disabledActions
            anchor(for: event.mode).addSublayer(layer)
        }
        configure(layer, for: placement)
        entries[event.id] = Entry(
            layer: layer,
            placement: placement,
            textureByteCost: payload.byteCost
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

    public func cancelAllPreparations() {
        preparationOwner.cancelAllPreparations()
    }

    /// 系统内存压力的响应：清空纹理缓存与已准备未挂上的纹理，在途准备以 `.capacity` 拒绝；
    /// 在屏的 layer 不受影响。
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
        removeAllEntries()
    }

    public func setCommandCards(_ cards: [DanmakuCommandCard]) {
        commandCardLayers.setCards(cards)
    }

    public func setOpacity(_ opacity: DanmakuOpacity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.opacity = Float(opacity.value)
        CATransaction.commit()
    }

    /// 窗口尺寸变化只移动三个锚点，不碰任何弹幕 layer 与动画。
    ///
    /// 不另包显式事务：`rootLayer` 与锚点已用 `actions` 禁用隐式动画，几何变化与调用方随后按新窗口
    /// 立即做的增删（纹理已就绪的挂上、取景框外的移除）落在同一次隐式提交里。缺纹理的弹幕就绪后才挂上，
    /// 这期间新露出的那块区域缺这几条。
    public func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        if backingScale != self.backingScale {
            self.backingScale = backingScale
            preparationOwner.cancelAllPreparations()
        }
        surfaceSize = CGSize(
            width: max(width.isFinite ? width : 0, 0),
            height: max(height.isFinite ? height : 0, 0)
        )
        rootLayer.frame = CGRect(origin: .zero, size: surfaceSize)
        scrollingAnchor.position = CGPoint(x: surfaceSize.width, y: 0)
        topAnchor.position = CGPoint(x: surfaceSize.width / 2, y: 0)
        bottomAnchor.position = CGPoint(x: surfaceSize.width / 2, y: surfaceSize.height)
        commandCardLayers.updateSurface(size: surfaceSize, backingScale: self.backingScale)
    }

    /// 会话结束：取消在途准备并清屏，互动弹幕卡片一并移除。
    public func stop() {
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
        commandCardLayers.setCards([])
    }

    /// 媒体时间换算成时钟层下的动画开始时间，弹幕与互动弹幕卡片共用。
    ///
    /// 0 写成 `mediaZero`（宿主注入的哨兵），否则会被当作「现在」。
    static func animationBeginTime(
        forMediaTime seconds: Double,
        mediaZero: CFTimeInterval
    ) -> CFTimeInterval {
        seconds > 0 ? seconds : mediaZero
    }

    private func animationBeginTime(forMediaTime seconds: Double) -> CFTimeInterval {
        Self.animationBeginTime(forMediaTime: seconds, mediaZero: beginTimeAtMediaZero)
    }

    /// 弹幕所属的锚点层；同一事件的模式不变，layer 一直挂在同一个锚点下。
    private func anchor(for mode: DanmakuPresentationMode) -> CALayer {
        switch mode {
        case .scrolling: scrollingAnchor
        case .top: topAnchor
        case .bottom: bottomAnchor
        }
    }

    /// 按 placement 设定 layer 在锚点局部坐标里的几何、不可见的模型值与唯一的动画；挂上与布局替换共用。
    ///
    /// 局部坐标 y 轴向下（继承 `rootLayer` 的翻转）。layer 的宽度只是正文纹理宽 t；合并弹幕的计数胶囊作为子层挂在
    /// 正文右侧、在 layer 边界之外，整条宽度 w 含胶囊的预留。滚动弹幕从正文左缘贴着右边缘（x = +t/2）走完
    /// `DanmakuMotionPolicy.scrollingTravel` 按 w 算的行程，胶囊右缘最终离开规划画布左外侧；顶部、底部弹幕按正文居中，
    /// 胶囊挂在右边；底部弹幕在底边之上，y 为负。
    private func configure(_ layer: CALayer, for placement: DanmakuLanePlacement) {
        let request = placement.request
        let width = request.textWidth
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: request.height)
        let animation: CABasicAnimation
        switch request.event.mode {
        case .scrolling:
            // 模型值在规划画布左外侧：动画开始之前与结束之后都看不见。
            let entryX = width / 2
            let exitX =
                entryX
                - DanmakuMotionPolicy.scrollingTravel(
                    textWidth: request.width,
                    planningWidth: placement.planningWidth
                )
            layer.position = CGPoint(x: exitX, y: placement.edgeOffset + request.height / 2)
            layer.opacity = 1
            animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = entryX
            animation.toValue = exitX
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .top, .bottom:
            let centerY = placement.edgeOffset + request.height / 2
            // 模型不透明度为 0，停留期间由不透明度为 1 的动画撑起。
            layer.position = CGPoint(
                x: 0,
                y: request.event.mode == .top ? centerY : -centerY
            )
            layer.opacity = 0
            animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
        }
        animation.beginTime = animationBeginTime(forMediaTime: placement.admittedAtSeconds)
        animation.duration = request.durationSeconds
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
        countBadgeLayers.replaceBadge(
            on: layer,
            badge: request.countBadge,
            textWidth: width,
            height: request.height,
            admittedAtSeconds: placement.admittedAtSeconds,
            beginTime: animation.beginTime,
            duration: request.durationSeconds,
            backingScale: backingScale
        )
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
}
