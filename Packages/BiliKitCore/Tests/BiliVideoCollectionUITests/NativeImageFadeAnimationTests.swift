import AppKit
import QuartzCore
import Testing

@testable import BiliVideoCollectionUI

/// 新到图片的淡入决定：要求淡入、图层存在且没开「减少动态效果」时才淡入；不淡入时当场回调，调用方立即撤下占位。
@MainActor
struct NativeImageFadeAnimationTests {
    @Test(arguments: [true, false])
    func fadesOnlyWhenRequestedAndMotionIsAllowed(animated: Bool) {
        let fade = NativeImageFadeAnimation(key: "test.fade")
        var finished = false
        let fades = fade.fadeIn(CALayer(), animated: animated) { finished = true }

        #expect(fades == (animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        // 淡入时的结束回调随 Core Animation 事务提交触发，时机取决于调度，所以只断言不淡入的一侧。
        if !fades {
            #expect(finished)
        }
    }

    @Test
    func missingLayerFinishesWithoutFading() {
        let fade = NativeImageFadeAnimation(key: "test.fade")
        var finished = false

        #expect(!fade.fadeIn(nil, animated: true) { finished = true })
        #expect(finished)
    }
}
