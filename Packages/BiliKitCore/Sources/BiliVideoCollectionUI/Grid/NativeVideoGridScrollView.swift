import AppKit

/// 网格的滚动视图：每次 `layout()` 都回调 `onViewportLayout`，contentInsets 变化时另行报告，由 Coordinator
/// 重排与保持位置。
///
/// 视口尺寸是否变化只由 Coordinator 按它最近一次排版的尺寸判断，这里不再比较尺寸：两份各带容差、基准不同的
/// 比较会分叉，Coordinator 认定尺寸已变、这里却不再回调，网格就一直停在等待排版的状态。
/// 只由 `NativeVideoGridView` 创建；用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoGridScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func layout() {
        super.layout()
        if let previousInsets = viewportTracker.update(for: self).previousInsets {
            onContentInsetsChange?(previousInsets, contentInsets)
        }
        onViewportLayout?()
    }
}
