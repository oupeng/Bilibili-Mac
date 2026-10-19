import Foundation
import QuartzCore

/// 整屏重排（画面尺寸或设置变化）时新旧两组弹幕的交叉淡化。
///
/// 弹幕 layer 都在宿主的同步 layer 之下，那里的局部时间是媒体时间，暂停时冻结；淡化必须按挂钟走完，
/// 所以淡入淡出放在同步 layer 之外的两个普通容器上：`incomingLayer` 包着宿主挂进来的同步 layer（新组
/// 在它下面），`outgoingLayer` 包着旧组。旧组离开同步 layer 后改由 `outgoingGroup` 自己的时间属性把
/// 挂钟换算成媒体时间（淡化开始时的媒体时间与速率），淡出期间仍按原速度走，暂停时静止。
///
/// 拥有 `containerLayer`、两个淡化容器、旧组与旧组纹理的索引；不拥有新组的 layer（renderer）。
/// 淡化结束的计时用注入的时钟：`start` 按 `duration` 睡眠后由 `generation` 比对决定是否收尾；
/// `begin`、`finish` 与新的 `start` 都递增 `generation`，被取代的计时到点不做任何事。淡化中再次重排、
/// seek、换 item、关闭弹幕时由调用方先 `finish`，旧组立即移除，新组立即完全显示。
@MainActor
final class DanmakuCrossfade {
    /// 淡入淡出的时长。
    ///
    /// 足以让全屏、缩放与改设置时的整屏换位不显得跳变，又短到不拖慢操作的反馈；调长会让两组重叠的时间
    /// 更久、画面更乱，调短则接近瞬间替换。
    static let duration = Duration.milliseconds(200)

    /// 宿主挂进视图 layer 树的最外层容器，与画面等大。
    let containerLayer = CALayer()
    private let incomingLayer = CALayer()
    private let outgoingLayer = CALayer()
    /// 淡出中的旧组；没有淡化时为 nil。
    private var outgoingGroup: CALayer?
    /// 旧组每条弹幕的纹理，按事件 ID；新组挂同一条弹幕时直接复用同一个 CGImage，不重新栅格化。
    private var outgoingImages: [String: (key: DanmakuTextureCacheKey, image: CGImage)] = [:]
    /// `begin`、`start` 与 `finish` 时递增；收尾计时带上开始时的值，不等就不收尾。
    private var generation: UInt64 = 0
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>, disabledActions: [String: any CAAction]) {
        self.clock = clock
        for layer in [containerLayer, incomingLayer, outgoingLayer] {
            layer.anchorPoint = .zero
            layer.actions = disabledActions
        }
        containerLayer.masksToBounds = true
        containerLayer.addSublayer(outgoingLayer)
        containerLayer.addSublayer(incomingLayer)
    }

    /// 是否有旧组在场（已开始淡化或还在等新组提交）。
    var isActive: Bool { outgoingGroup != nil }

    /// 宿主的同步 layer 挂进淡入容器，弹幕的 `rootLayer` 挂在同步 layer 下。
    func mount(clockLayer: CALayer, contentLayer: CALayer) {
        incomingLayer.addSublayer(clockLayer)
        clockLayer.addSublayer(contentLayer)
    }

    /// 三个容器与旧组跟随画面尺寸。
    func setFrame(_ frame: CGRect) {
        containerLayer.frame = frame
        incomingLayer.frame = containerLayer.bounds
        outgoingLayer.frame = containerLayer.bounds
        outgoingGroup?.frame = containerLayer.bounds
    }

    /// 新组挂同一条弹幕时可复用的旧纹理；纹理 key 不同（scale 或外观变了）时为 nil。
    func reusableImage(for eventID: String, key: DanmakuTextureCacheKey) -> CGImage? {
        guard let reused = outgoingImages[eventID], reused.key == key else { return nil }
        return reused.image
    }

    /// 把当前在屏的 layer 整组移到淡出容器，此刻仍完全显示，等 `start` 才开始淡化。
    ///
    /// `template` 是新组的父 layer，旧组复制它的几何与用户透明度。旧组按 `mediaTime` 与 `rate`
    /// 自己换算媒体时间：局部时间 =（父时间 − beginTime）× speed + timeOffset。
    func begin(
        layers: [(eventID: String, layer: CALayer, key: DanmakuTextureCacheKey, image: CGImage)],
        template: CALayer,
        mediaTime: Double,
        rate: Double
    ) {
        finish()
        guard !layers.isEmpty else { return }
        let group = CALayer()
        group.anchorPoint = template.anchorPoint
        group.isGeometryFlipped = template.isGeometryFlipped
        group.masksToBounds = template.masksToBounds
        group.actions = template.actions
        group.frame = containerLayer.bounds
        group.opacity = template.opacity
        group.beginTime = outgoingLayer.convertTime(CACurrentMediaTime(), from: nil)
        group.timeOffset = mediaTime
        group.speed = Float(rate.isFinite ? max(rate, 0) : 0)
        for item in layers {
            group.addSublayer(item.layer)
            outgoingImages[item.eventID] = (item.key, item.image)
        }
        outgoingLayer.addSublayer(group)
        outgoingGroup = group
    }

    /// 新组已经挂好：旧组淡出、新组淡入，按挂钟在 `duration` 后收尾。
    ///
    /// 没有旧组时什么都不做。
    func start() {
        guard outgoingGroup != nil else { return }
        generation &+= 1
        let started = generation
        let seconds = Self.durationSeconds
        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.duration = seconds
        fadeOut.beginTime = outgoingLayer.convertTime(CACurrentMediaTime(), from: nil)
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.duration = seconds
        fadeIn.beginTime = incomingLayer.convertTime(CACurrentMediaTime(), from: nil)
        // 模型值先设为终点：动画结束移除后停在终点，不回跳。
        outgoingLayer.opacity = 0
        incomingLayer.opacity = 1
        outgoingLayer.add(fadeOut, forKey: Self.animationKey)
        incomingLayer.add(fadeIn, forKey: Self.animationKey)
        Task { @MainActor [weak self, clock] in
            try? await clock.sleep(for: Self.duration)
            guard let self, self.generation == started else { return }
            self.finish()
        }
    }

    /// 立即结束淡化：移除旧组，新组完全显示；没有淡化时是空操作。
    func finish() {
        generation &+= 1
        outgoingLayer.removeAnimation(forKey: Self.animationKey)
        incomingLayer.removeAnimation(forKey: Self.animationKey)
        outgoingLayer.opacity = 1
        incomingLayer.opacity = 1
        if let group = outgoingGroup {
            for layer in group.sublayers ?? [] {
                layer.removeAllAnimations()
                layer.removeFromSuperlayer()
            }
            group.removeFromSuperlayer()
        }
        outgoingGroup = nil
        outgoingImages.removeAll(keepingCapacity: false)
    }

    /// 淡入淡出动画的 key。
    static let animationKey = "crossfade"

    private static var durationSeconds: CFTimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
