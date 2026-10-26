import AppKit
import SwiftUI

/// 承载评论图片预览的子窗口面板：无边框、透明底，铺满父窗口；点暗底、Esc 或 ⌘W 关闭。
///
/// 用 AppKit 面板而不是 SwiftUI overlay、sheet 或 Quick Look：见 docs/ARCHITECTURE.md「原生 AppKit 集合视图」。
/// 刻意无边框：带标题栏的窗口有标题栏与工具栏的约束，内容又是 SwiftUI 宿主，窗口尺寸会被内容和标题栏反复推动，
/// 显示周期里的约束更新停不下来；无边框窗口没有这些约束，AppKit 也不把它推回屏幕可见区域，父窗口部分在屏幕外时
/// 照样与之重合。代价是圆角要自己裁（见 `cornerRadius(matching:)`）。
///
/// 内容是一个按 frame 布局的普通容器视图，SwiftUI 宿主以自动伸缩填满它：宿主不产生尺寸约束（`sizingOptions`
/// 为空）、不桥接标题与工具栏（`sceneBridgingOptions` 为空）、不按安全区缩进，面板尺寸只由 presenter 按父窗口
/// 设置。不可移动、不在 App 失活时隐藏、可进入父窗口所在的全屏空间。只拥有关闭回调与容器，关闭顺序由
/// `NativeCommentImagePreviewPresenter` 决定。
@MainActor
final class NativeCommentImagePreviewPanel: NSPanel {
    /// macOS 26 起系统窗口的圆角半径（macOS 27 实测，带不带工具栏相同），面板四角按它裁、与父窗口重合。
    ///
    /// 与系统不一致时四角会露出一点暗底或父窗口内容，只影响观感。
    private static let windowCornerRadius: CGFloat = 16
    /// macOS 15 系统窗口的圆角半径。
    private static let legacyWindowCornerRadius: CGFloat = 10

    /// 用户要求关闭（⌘W、未被预览内容处理的 Esc，以及预览内容的关闭按钮与点暗底）；由 presenter 设置。
    var onRequestClose: () -> Void = {}
    private let container = NSView()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // 无边框窗口不显示标题，但读屏仍以它称呼这个窗口。
        title = VideoDetailFeatureStrings.localized("评论图片预览")
        isOpaque = false
        backgroundColor = .clear
        // 父窗口已有阴影；面板与它重合，再画一层会加深边缘。
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        // NSPanel 默认在 App 失活时隐藏；切到别的 App 再回来时预览应当还在。
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary]
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerCurve = .continuous
        contentView = container
    }

    /// 无边框窗口默认不能成为 key；预览要接收 Esc、←→ 与 ⌘S。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 放入预览内容：宿主以自动伸缩填满容器，不用约束，也不让 SwiftUI 管理面板的尺寸、标题与工具栏。
    func host(_ rootView: some View) {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.sceneBridgingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
    }

    /// 拆掉预览内容：SwiftUI 的 `.task` 随之取消，内容持有的原图一起释放。
    func removeContent() {
        for subview in container.subviews { subview.removeFromSuperview() }
    }

    /// 与父窗口重合：frame 相同时不设，四角按父窗口是否全屏裁圆角。
    func match(_ parent: NSWindow) {
        container.layer?.cornerRadius = Self.cornerRadius(matching: parent)
        guard frame != parent.frame else { return }
        setFrame(parent.frame, display: true)
    }

    /// AppKit 没有公开的窗口圆角半径：全屏时为 0，否则按系统版本取常量。
    private static func cornerRadius(matching parent: NSWindow) -> CGFloat {
        if parent.styleMask.contains(.fullScreen) { return 0 }
        if #available(macOS 26.0, *) { return windowCornerRadius }
        return legacyWindowCornerRadius
    }

    /// ⌘W 关闭预览，而不是关闭面板本身或越过它关掉主窗口。
    override func performClose(_ sender: Any?) {
        onRequestClose()
    }

    /// 无边框窗口没有 `.closable`，系统默认会停用「关闭」菜单项；这里让 ⌘W 仍可用来关闭预览。
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)) { return true }
        return super.validateMenuItem(menuItem)
    }

    /// 预览内容没有处理 Esc（例如焦点不在预览表面上）时，同样关闭预览。
    override func cancelOperation(_ sender: Any?) {
        onRequestClose()
    }
}
