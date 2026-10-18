import Foundation
import QuartzCore

/// 把单个弹幕 layer 的动画结束转回 MainActor 上的
/// `CoreAnimationDanmakuRenderer.completeAnimation`。
///
/// `CAAnimation` 强引用 delegate，这里只弱引用 renderer，避免 renderer → layer → 动画 → relay →
/// renderer 成环。回调是 nonisolated，经 `Task { @MainActor }` 异步回到 renderer，到达时 layer
/// 可能已被移除或换成同一事件 ID 的新对象，所以带上 `objectIdentity` 与 `renderEpoch` 交给
/// renderer 比对，不匹配的迟到回调被丢弃。被主动移除的动画同样会回调（`finished` 为 false），因
/// entry 已不在或已换成新对象而被丢弃；`finished` 不参与判断。
final class AnimationCompletionRelay: NSObject, CAAnimationDelegate {
    weak var renderer: CoreAnimationDanmakuRenderer?
    let eventID: String
    let objectIdentity: UInt64
    let renderEpoch: UInt64

    init(
        renderer: CoreAnimationDanmakuRenderer,
        eventID: String,
        objectIdentity: UInt64,
        renderEpoch: UInt64
    ) {
        self.renderer = renderer
        self.eventID = eventID
        self.objectIdentity = objectIdentity
        self.renderEpoch = renderEpoch
    }

    nonisolated func animationDidStop(
        _ animation: CAAnimation,
        finished flag: Bool
    ) {
        let renderer = renderer
        let eventID = eventID
        let objectIdentity = objectIdentity
        let renderEpoch = renderEpoch
        Task { @MainActor [weak renderer] in
            renderer?.completeAnimation(
                eventID: eventID,
                objectIdentity: objectIdentity,
                renderEpoch: renderEpoch
            )
        }
    }
}
