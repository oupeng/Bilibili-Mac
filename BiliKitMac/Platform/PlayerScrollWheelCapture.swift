import AppKit

/// 普通窗口中位于 AVPlayerView 原生子视图（含控制条）上方的 scroll-only direct child。
///
/// 只对 scroll-wheel 参与 hit testing 并吞掉事件；点击、拖动、magnify、键盘与辅助功能穿透给 AVKit。
@MainActor
final class PlayerScrollWheelShieldView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        PlayerScrollWheelCaptureView.capturesEvent(ofType: NSApp.currentEvent?.type)
            ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {}

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

/// 安装在 AVKit 公开 content overlay 中、位于原生控制条下方的透明滚轮命中层。
///
/// 播放页主区不滚动，播放器上的滚轮一律不产生动作：本层与窗口内的 shield 吞掉 scroll-wheel，
/// 不交给 AVKit 内部视图。其他输入穿透。它也是键盘快捷键的窗口锚点：`keyboardShortcuts`
/// 跟随本视图所在窗口；AVKit detached 全屏只携带 content overlay，锚点因此必须留在这里。
@MainActor
final class PlayerScrollWheelCaptureView: NSView {
    let keyboardShortcuts = PlayerKeyboardShortcutController()
    private var windowResignObservers = NativeVideoNotificationObservers()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        keyboardShortcuts.anchorView = self
    }

    static func capturesEvent(ofType type: NSEvent.EventType?) -> Bool {
        type == .scrollWheel
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.capturesEvent(ofType: NSApp.currentEvent?.type) ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {}

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingWindowFocusLoss()
            cancelInputSession()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        keyboardShortcuts.startMonitoring()
        windowResignObservers.removeAll()
        windowResignObservers.observe(
            NSWindow.didResignKeyNotification,
            object: window
        ) { [weak self] in
            self?.cancelInputSession()
        }
    }

    func cancelInputSession() {
        keyboardShortcuts.cancelInputSession()
    }

    func stopKeyboardMonitoring() {
        cancelInputSession()
        keyboardShortcuts.stopMonitoring()
        stopObservingWindowFocusLoss()
    }

    private func stopObservingWindowFocusLoss() {
        windowResignObservers.removeAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
