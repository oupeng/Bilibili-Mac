import AppKit

/// 视图里一组限定区域的点击入口：只在这些区域内响应单击，并显示与视频卡片一致的手形指针。
///
/// 点击手势挂在宿主视图上，子视图的点击也会送到这里；不限定区域的话，点到正文或签名也会误触发。
/// 宿主在 init 里调用一次 `attach(to:onClick:)`，布局或内容变化后用 `setRects(_:)` 给出当前区域，
/// 并在 `resetCursorRects()` 里调用 `addCursorRects()`。
@MainActor
final class NativeClickRegion: NSObject, NSGestureRecognizerDelegate {
    private weak var host: NSView?
    private var onClick: (@MainActor () -> Void)?
    /// 宿主坐标系里的可点区域；为空时整块都不可点。
    private(set) var rects: [NSRect] = []
    /// 已登记给窗口的区域；宿主不在窗口里时清空，进入窗口后的第一次更新一定会重新登记。
    private var registeredRects: [NSRect] = []
    private lazy var recognizer = NSClickGestureRecognizer(
        target: self,
        action: #selector(click)
    )

    func attach(to host: NSView, onClick: @escaping @MainActor () -> Void) {
        self.host = host
        self.onClick = onClick
        recognizer.delegate = self
        host.addGestureRecognizer(recognizer)
    }

    func setRects(_ rects: [NSRect]) {
        self.rects = rects.filter { !$0.isEmpty }
        guard let host, let window = host.window else {
            registeredRects = []
            return
        }
        guard self.rects != registeredRects else { return }
        registeredRects = self.rects
        window.invalidateCursorRects(for: host)
    }

    func addCursorRects() {
        for rect in rects {
            host?.addCursorRect(rect, cursor: .pointingHand)
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
        guard let host else { return false }
        let location = gestureRecognizer.location(in: host)
        return rects.contains { $0.contains(location) }
    }

    @objc private func click() {
        onClick?()
    }
}
