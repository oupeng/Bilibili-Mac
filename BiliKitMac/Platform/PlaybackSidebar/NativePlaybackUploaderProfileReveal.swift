import AppKit
import BiliVideoDetailFeature

/// UP 主名片晚于详情到达时的过渡。
///
/// 名字颜色与签名在 UP 主行自身的一次淡入里换成结果，而不是瞬间跳变。UP 主行在名片各状态下
/// 等高（由头像高度决定），下方行不会位移，所以过渡只需要覆盖这一行。
@MainActor
enum NativePlaybackUploaderProfileReveal {
    static let duration: CFTimeInterval = 0.25

    /// 同一行原地从“名片加载中”变为结果；首次配置与复用后的配置都不算。
    static func fades(
        from previous: VideoUploaderHeaderContent?,
        to next: VideoUploaderHeaderContent
    ) -> Bool {
        previous?.isProfileLoading == true && !next.isProfileLoading
    }

    /// 在当前 `CATransaction` 提交前、内容改动之前挂上淡入；同一事务里之后的图层变化都会淡入呈现。
    static func apply(to view: NSView) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            let layer = view.layer
        else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: "native-playback-uploader.profile-reveal")
    }
}
