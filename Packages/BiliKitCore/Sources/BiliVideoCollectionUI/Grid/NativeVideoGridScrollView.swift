import AppKit

/// 网格的滚动视图：在 `layout()` 里报告视口尺寸与 contentInsets 的变化，由 Coordinator 重排与保持位置。
///
/// 只由 `NativeVideoGridView` 创建；用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoGridScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func layout() {
        super.layout()
        let change = viewportTracker.update(for: self)
        if let previousInsets = change.previousInsets {
            onContentInsetsChange?(previousInsets, contentInsets)
        }
        if change.sizeChanged { onViewportLayout?() }
    }
}
