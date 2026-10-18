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

    /// 已上屏 layer 的纹理字节总上限；超出时新弹幕不上屏，呈现控制器计为容量丢弃。
    ///
    /// 与活动数硬上限一起限定最坏情况的纹理内存：调大允许更多长文本同屏，调小则高峰期更早丢弃。
    static let maximumActiveTextureByteCost = 64 * 1_024 * 1_024
    /// 每个弹幕 layer 上唯一的位移／停留动画的 key。
    static let animationKey = "danmaku"

    public weak var delegate: (any DanmakuRenderingBackendDelegate)?
    public let rootLayer: CALayer

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

    public init(contentsScale: Double = 2) {
        backingScale = Self.normalizedBackingScale(contentsScale)
        preparationOwner = DanmakuTexturePreparationOwner()
        rootLayer = CALayer()
        rootLayer.anchorPoint = .zero
        // y 轴向下，与 allocator 自顶边计算的 `originY` 一致。
        rootLayer.isGeometryFlipped = true
        rootLayer.masksToBounds = true
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
        let normalizedScale = Self.normalizedBackingScale(backingScale)
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

    /// 在保持当前 layer 局部时间连续的前提下暂停或调整动画速率。
    public func setPlaybackRate(_ rate: Double) {
        let newRate = rate.isFinite ? max(rate, 0) : 0
        guard Double(rootLayer.speed) != newRate else { return }
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

    public func setOpacity(_ opacity: DanmakuOpacity) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer.opacity = Float(opacity.value)
        CATransaction.commit()
    }

    public func updateSurfaceSize(width: Double, height: Double) {
        updateSurfaceSize(
            width: width,
            height: height,
            backingScale: backingScale
        )
    }

    public func updateSurfaceSize(
        width: Double,
        height: Double,
        backingScale: Double
    ) {
        let normalizedScale = Self.normalizedBackingScale(backingScale)
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

    public func stop() {
        advanceEpoch()
        preparationOwner.cancelAllPreparations()
        removeAllEntries()
        setPlaybackRate(0)
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
        entry.layer.removeAllAnimations()
        entry.layer.removeFromSuperlayer()
    }

    private static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite
            ? min(max(scale, 1), DanmakuTextureRasterizer.maximumBackingScale)
            : 2
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
