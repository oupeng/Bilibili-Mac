import AppKit
import QuartzCore
import SwiftUI

/// SwiftUI 一侧新到图片的淡入：评论图片预览与 App 侧栏账号头像共用，时长与 AppKit 侧的
/// `NativeImageFadeAnimation` 相同，观感一致。
///
/// 只给出动画，调用方用它包住写入新图的状态变更；`reduceMotion` 取调用方视图的
/// `accessibilityReduceMotion` 环境值。`public` 是因为 App 的侧栏账号头像也用它。
public enum NativeImageFadeTransition {
    /// 需要淡入且没开「减少动态效果」时为 ease-out 淡入，否则为 nil（直接显示）。
    @MainActor
    public static func animation(fadesIn: Bool, reduceMotion: Bool) -> Animation? {
        fadesIn && !reduceMotion ? .easeOut(duration: NativeImageFadeAnimation.duration) : nil
    }
}

/// 新到图片的淡入动画核心：卡片封面与头像（`NativeVideoImageFade`）、评论头像与评论图片格子共用，观感一致。
///
/// 每个显示图片的视图持有一个；不拥有图层，也不决定图层内容与占位怎么显示，只负责在给定图层上做透明度
/// 0→1 的淡入，并在淡入结束时回调调用方撤下占位。`generation` 在每次 `fadeIn` 与 `cancel` 时递增，结束回调
/// 只在其间没有新的淡入或取消时执行；否则旧动画结束会把新设置刚显示的占位撤掉。系统开了「减少动态效果」时
/// 不做动画、立即回调。只在主线程使用。
@MainActor
package final class NativeImageFadeAnimation {
    /// 淡入时长：够看出新图到达，又短到快速滚动时不拖尾。
    ///
    /// SwiftUI 一侧的 `NativeImageFadeTransition` 沿用同一时长。
    package static let duration: CFTimeInterval = 0.15

    private let key: String
    private var generation: UInt64 = 0

    /// `key` 是加在图层上的动画键，每种视图用自己的键，便于移除时只动自己的动画。
    package init(key: String) {
        self.key = key
    }

    /// 作废进行中的淡入：移除动画、透明度复位，旧动画的结束回调不再执行。
    ///
    /// 换图、清空或释放时调用。
    package func cancel(on layer: CALayer?) {
        generation &+= 1
        layer?.removeAnimation(forKey: key)
        layer?.opacity = 1
    }

    /// 图层的新内容设置好之后调用。
    ///
    /// 需要淡入（`animated`）、图层存在且没开「减少动态效果」时做淡入并返回 true，结束后调用 `onFinished`；
    /// 否则立即调用 `onFinished` 并返回 false。调用方据返回值决定淡入期间是否还显示占位。
    @discardableResult
    package func fadeIn(
        _ layer: CALayer?,
        animated: Bool,
        onFinished: @escaping @MainActor () -> Void
    ) -> Bool {
        cancel(on: layer)
        guard animated,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let layer
        else {
            onFinished()
            return false
        }
        let currentGeneration = generation
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = Self.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            onFinished()
        }
        layer.add(animation, forKey: key)
        CATransaction.commit()
        return true
    }
}
