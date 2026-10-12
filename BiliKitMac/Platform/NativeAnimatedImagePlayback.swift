import AppKit
import ImageIO

/// 在一个宿主视图里播放评论动图：用 ImageIO 边解码边播放，不预先解出所有帧，始终无限循环。
///
/// 只在宿主真正可见时播放：在窗口里、自身与祖先都没隐藏、可见区域非空、窗口没被完全遮住，并且系统
/// 没有开启「减少动态效果」。播放中每帧检查一次，不满足就停下并让宿主恢复第一帧；有动图期间监听滚动、
/// 窗口遮挡与辅助功能设置的变化，条件恢复时从头重新播放。宿主进出窗口、隐藏或显示、布局完成时调用
/// `hostVisibilityDidChange()`。
@MainActor
final class NativeAnimatedImagePlayback {
    /// 一次 ImageIO 播放；停下后迟到的帧回调直接结束。
    private final class Session {
        var isStopped = false
        var hasShownFrame = false
    }

    private weak var host: NSView?
    private let onFrame: (CGImage) -> Void
    private let onRestoreFirstFrame: () -> Void
    private var animation: NativeAnimatedImage?
    /// ImageIO 不支持这份数据时记住，滚动时不再反复重试；换了动图才清除。
    private var hasFailed = false
    private var session: Session?
    private var observers = NativeVideoNotificationObservers()
    private var isObserving = false
    private weak var observedWindow: NSWindow?
    private weak var observedClipView: NSClipView?

    init(
        host: NSView,
        onFrame: @escaping (CGImage) -> Void,
        onRestoreFirstFrame: @escaping () -> Void
    ) {
        self.host = host
        self.onFrame = onFrame
        self.onRestoreFirstFrame = onRestoreFirstFrame
    }

    isolated deinit {
        session?.isStopped = true
        observers.removeAll()
    }

    /// 换成另一张动图（或 nil 停止）；同一张动图重复设置时保持当前播放。
    func play(_ animation: NativeAnimatedImage?) {
        guard animation !== self.animation else {
            update()
            return
        }
        stopSession()
        self.animation = animation
        hasFailed = false
        update()
    }

    func stop() {
        animation = nil
        hasFailed = false
        stopSession()
        removeObservers()
    }

    func hostVisibilityDidChange() {
        update()
    }

    private var canPlay: Bool {
        guard let host, let window = host.window,
            !host.isHiddenOrHasHiddenAncestor,
            !host.visibleRect.isEmpty,
            window.occlusionState.contains(.visible)
        else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func update() {
        guard let animation, !hasFailed else {
            stopSession()
            removeObservers()
            return
        }
        installObserversIfNeeded()
        if canPlay {
            start(animation)
        } else {
            stopSession()
        }
    }

    private func start(_ animation: NativeAnimatedImage) {
        guard session == nil else { return }
        let session = Session()
        self.session = session
        let options = [kCGImageAnimationLoopCount: kCFNumberPositiveInfinity] as CFDictionary
        let status = CGAnimateImageDataWithBlock(animation.data as CFData, options) {
            [weak self] _, image, stop in
            // ImageIO 在主队列回调。
            MainActor.assumeIsolated {
                guard let self, !session.isStopped, self.session === session, self.canPlay else {
                    stop.pointee = true
                    if let self, self.session === session { self.stopSession() }
                    return
                }
                session.hasShownFrame = true
                self.onFrame(image)
            }
        }
        if status != noErr, self.session === session {
            self.session = nil
            hasFailed = true
            removeObservers()
        }
    }

    /// 停下当前播放；已经画过帧时让宿主恢复第一帧（「减少动态效果」只显示第一帧）。
    private func stopSession() {
        guard let session else { return }
        session.isStopped = true
        self.session = nil
        if session.hasShownFrame {
            onRestoreFirstFrame()
        }
    }

    /// 宿主所在窗口或滚动区域变了才重装监听，滚动中反复调用不重复注册。
    private func installObserversIfNeeded() {
        let window = host?.window
        let clipView = host?.enclosingScrollView?.contentView
        guard !isObserving || window !== observedWindow || clipView !== observedClipView
        else { return }
        removeObservers()
        isObserving = true
        observedWindow = window
        observedClipView = clipView
        let reevaluate: @MainActor @Sendable () -> Void = { [weak self] in self?.update() }
        if let window {
            observers.observe(
                NSWindow.didChangeOcclusionStateNotification,
                object: window,
                handler: reevaluate
            )
        }
        if let scrollView = host?.enclosingScrollView {
            observers.observeScrolling(of: scrollView, handler: reevaluate)
        }
        observers.observeAccessibilityDisplayOptions(handler: reevaluate)
    }

    private func removeObservers() {
        observers.removeAll()
        isObserving = false
        observedWindow = nil
        observedClipView = nil
    }
}
