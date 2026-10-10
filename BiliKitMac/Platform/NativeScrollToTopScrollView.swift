import AppKit

/// 右下角带“返回顶部”玻璃按钮的滚动视图；播放侧栏评论区与 UP 主空间共用。
///
/// 按钮的显隐与目标位置由 owner 决定；这里只负责外观、贴着安全区的位置与内容边距变化通知。
@MainActor
final class NativeScrollToTopScrollView: NSScrollView {
    private enum Geometry {
        static let buttonSize: CGFloat = 44
        static let edgeInset: CGFloat = 16
    }

    let topButton: NSButton
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    init(topButtonLabel: String) {
        topButton = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.up",
                accessibilityDescription: topButtonLabel
            ) ?? NSImage(),
            target: nil,
            action: nil
        )
        super.init(frame: .zero)
        topButton.imagePosition = .imageOnly
        topButton.imageScaling = .scaleProportionallyDown
        topButton.controlSize = .large
        if #available(macOS 26.0, *) {
            topButton.bezelStyle = .glass
        } else {
            topButton.bezelStyle = .circular
        }
        topButton.setAccessibilityLabel(topButtonLabel)
        topButton.toolTip = topButtonLabel
        topButton.isHidden = true
        addSubview(topButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        let safeTrailing = max(contentInsets.right, safeAreaInsets.right)
        let safeBottom = max(contentInsets.bottom, safeAreaInsets.bottom)
        let offset = Geometry.edgeInset + Geometry.buttonSize
        let bottomAlignedY = max(Geometry.edgeInset, bounds.height - safeBottom - offset)
        topButton.frame = NSRect(
            x: max(Geometry.edgeInset, bounds.width - safeTrailing - offset),
            y: isFlipped ? bottomAlignedY : safeBottom + Geometry.edgeInset,
            width: Geometry.buttonSize,
            height: Geometry.buttonSize
        )
        guard let previousInsets = viewportTracker.update(for: self).previousInsets else { return }
        onContentInsetsChange?(previousInsets, contentInsets)
    }
}
