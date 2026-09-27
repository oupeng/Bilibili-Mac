import AppKit

/// 键盘快捷键的窗口锚点：不参与任何命中测试，只让 `keyboardShortcuts` 跟随所在窗口。
///
/// 安装在 AVKit 公开的 content overlay 中；AVKit detached 全屏只携带 content overlay，锚点因此随
/// 播放器进入全屏窗口，快捷键继续生效。窗口失去 key 时取消进行中的长按临时倍速。
@MainActor
final class PlayerKeyboardAnchorView: NSView {
    let keyboardShortcuts = PlayerKeyboardShortcutController()
    private var windowResignObservers = NativeVideoNotificationObservers()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        keyboardShortcuts.anchorView = self
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

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
