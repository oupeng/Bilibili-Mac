import AppKit
import BiliModels
import QuartzCore

/// 互动弹幕卡片（评分、投票）的 Core Animation 层：按媒体时间显隐，按窗口尺寸定位，不占车道。
///
/// 由 `CoreAnimationDanmakuRenderer` 持有；`containerLayer` 挂在 renderer 的 `rootLayer` 下、所有弹幕之上，与窗口同尺寸，
/// 所以用户透明度与裁剪随 `rootLayer`。拥有当前卡片与各自的 layer：`setCards` 整组替换，`updateSurface` 只重新定位，
/// 换 backing scale 时重画卡片图。显隐是从卡片时间点开始、持续显示时长的不透明度动画（模型值 0），与顶部弹幕同一
/// 做法，由时钟层按媒体时间切换，不随对齐步长刷新，暂停、seek、倍速都与连续播放一致。
@MainActor
final class DanmakuCommandCardLayers {
    /// 卡片离窗口边缘至少留出的距离（point）；位置超出时往里收。
    static let edgeMargin: CGFloat = 12
    /// 卡片 layer 上唯一的显隐动画的 key。
    static let animationKey = "danmaku.commandCard"

    let containerLayer = CALayer()
    private var cards: [DanmakuCommandCard] = []
    private var layers: [CALayer] = []
    private var surfaceSize = CGSize.zero
    private var backingScale: Double
    /// 媒体时间换算成时钟层下的动画开始时间，与弹幕动画同一规则（见 `CoreAnimationDanmakuRenderer`）。
    private let beginTime: (Double) -> CFTimeInterval

    init(backingScale: Double, beginTime: @escaping (Double) -> CFTimeInterval) {
        self.backingScale = backingScale
        self.beginTime = beginTime
        containerLayer.anchorPoint = .zero
        containerLayer.actions = CoreAnimationDanmakuRenderer.disabledActions
    }

    /// 整组换成 `cards`；与当前相同时什么都不做。
    func setCards(_ cards: [DanmakuCommandCard]) {
        guard cards != self.cards else { return }
        self.cards = cards
        rebuild()
    }

    /// 窗口尺寸或 backing scale 变化：尺寸只重新定位，scale 变了才重画卡片图。
    func updateSurface(size: CGSize, backingScale: Double) {
        containerLayer.frame = CGRect(origin: .zero, size: size)
        let scaleChanged = backingScale != self.backingScale
        self.backingScale = backingScale
        surfaceSize = size
        if scaleChanged {
            rebuild()
        } else {
            layoutCards()
        }
    }

    private func rebuild() {
        for layer in layers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        layers = cards.map { card in
            let layer = CALayer()
            layer.actions = CoreAnimationDanmakuRenderer.disabledActions
            let scale = CGFloat(backingScale)
            if let artwork = DanmakuCommandCardArtwork.artwork(for: card, scale: scale) {
                layer.contents = artwork.image
                layer.bounds = CGRect(origin: .zero, size: artwork.size)
            }
            layer.contentsScale = CGFloat(backingScale)
            layer.contentsGravity = .resize
            // 模型不透明度为 0，显示期间由不透明度为 1 的动画撑起。
            layer.opacity = 0
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 1
            animation.toValue = 1
            animation.beginTime = beginTime(card.timeSeconds)
            animation.duration = card.durationSeconds
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: Self.animationKey)
            containerLayer.addSublayer(layer)
            return layer
        }
        layoutCards()
    }

    /// 卡片中心按位置比例落在窗口里，超出时往里收到离边缘 `edgeMargin`；窗口比卡片还窄时居中。
    private func layoutCards() {
        for (card, layer) in zip(cards, layers) {
            layer.position = Self.center(
                for: card.position,
                cardSize: layer.bounds.size,
                in: surfaceSize
            )
        }
    }

    /// 局部坐标 y 轴向下（继承 `rootLayer` 的翻转），所以位置比例的 y 直接是离顶边的比例。
    static func center(
        for position: DanmakuCardPosition,
        cardSize: CGSize,
        in surface: CGSize
    ) -> CGPoint {
        func clamp(_ value: CGFloat, extent: CGFloat, length: CGFloat) -> CGFloat {
            let lower = edgeMargin + extent / 2
            let upper = length - edgeMargin - extent / 2
            guard lower <= upper else { return length / 2 }
            return min(max(value, lower), upper)
        }
        return CGPoint(
            x: clamp(surface.width * position.x, extent: cardSize.width, length: surface.width),
            y: clamp(surface.height * position.y, extent: cardSize.height, length: surface.height)
        )
    }
}
