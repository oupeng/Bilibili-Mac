import AppKit
import BiliVideoCollectionUI
import SwiftUI

/// 评论图片预览的窗口级 owner：把预览放进铺满父窗口的子窗口面板，换视频、关窗时关闭。
///
/// 父窗口是被点开的格子所在的窗口（侧栏只在主窗口里，AVKit detached 全屏时同样挂在主窗口上）。面板有自己的
/// key window：播放器的按键监视只截获播放窗口的事件，Esc、←→ 与 ⌘S 直接交给预览，导航与侧栏不必为预览守护，
/// 见 docs/ARCHITECTURE.md「原生 AppKit 集合视图」。
///
/// 拥有当前面板、它的宿主视图与父窗口的通知观察；不拥有图片管线、保存（`NativeCommentImageSaver`，同属窗口级，
/// 关窗时由窗口组装另行取消）与格子本身。同一时间最多一个预览，再次打开先无动画地关掉旧的。MainActor 隔离。
///
/// 关闭顺序（`dismiss`）：先移除通知观察；再结束挂在面板上的 sheet（保存面板按取消结束，`isBusy` 随之复位）；
/// 然后从父窗口摘下面板；用户关闭时把父窗口设为 key 并把焦点交还格子；最后隐藏面板并拆掉宿主视图，SwiftUI 的
/// `.task` 随之取消在途原图加载、释放本次预览持有的原图。先摘子窗口再交还焦点：面板仍是子窗口时父窗口成为 key
/// 会被面板盖住。淡出期间面板已不接收鼠标，也不再是子窗口。
@MainActor
public final class NativeCommentImagePreviewPresenter {
    /// 打开与关闭的淡入淡出时长；「减少动态效果」时不做。
    ///
    /// 只影响观感，不影响关闭顺序：淡出开始前面板已摘下、焦点已交还。
    private static let fadeDuration: TimeInterval = 0.15

    private struct Presentation {
        let request: NativeCommentImagePreviewRequest
        let panel: NativeCommentImagePreviewPanel
        weak var parent: NSWindow?
        var observers: NativeVideoNotificationObservers
    }

    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver
    private let imageSaver: NativeCommentImageSaver
    private var presentation: Presentation?

    public init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver,
        imageSaver: NativeCommentImageSaver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
        self.imageSaver = imageSaver
    }

    /// 打开预览；格子已不在窗口里时不打开。
    ///
    /// 调用方只在 `request.bvid` 是当前播放视频时调用。
    public func present(_ request: NativeCommentImagePreviewRequest) {
        dismiss(restoringFocus: false, animated: false)
        guard let parent = request.sourceWindow() else { return }
        let panel = NativeCommentImagePreviewPanel()
        let anchor = NativeCommentImagePreviewAnchor()
        anchor.window = panel
        panel.onRequestClose = { [weak self, weak panel] in
            guard let self, let panel, self.presentation?.panel === panel else { return }
            self.dismiss(restoringFocus: true, animated: true)
        }
        let hostingView = NSHostingView(
            rootView: NativeCommentImagePreviewView(
                request: request,
                imagePipeline: imagePipeline,
                resolveURL: resolveURL,
                imageSaver: imageSaver,
                anchor: anchor,
                onDismiss: { [weak panel] in panel?.onRequestClose() }
            )
        )
        // 面板尺寸只跟随父窗口；宿主不按内容反推窗口尺寸，也不按标题栏安全区缩进暗底。
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
        panel.setFrame(parent.frame, display: false)

        var observers = NativeVideoNotificationObservers()
        // 子窗口随父窗口移动，但不随它改变尺寸（含进出原生全屏）。
        observers.observe(NSWindow.didResizeNotification, object: parent) {
            [weak panel, weak parent] in
            guard let panel, let parent else { return }
            panel.setFrame(parent.frame, display: true)
        }
        observers.observe(NSWindow.willCloseNotification, object: parent) { [weak self] in
            self?.dismiss(restoringFocus: false, animated: false)
        }
        presentation = Presentation(
            request: request,
            panel: panel,
            parent: parent,
            observers: observers
        )

        let animated = Self.animates
        panel.alphaValue = animated ? 0 : 1
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fadeDuration
                panel.animator().alphaValue = 1
            }
        }
    }

    /// 播放的视频变化（含退出播放）时由 App 调用：预览属于别的视频就关闭，不交还焦点。
    public func playbackDidChange(to bvid: String?) {
        guard let presentation, presentation.request.bvid != bvid else { return }
        dismiss(restoringFocus: false, animated: false)
    }

    /// 关窗时由窗口组装调用：立即关闭，不交还焦点；须在取消图片保存之前，先让挂在面板上的保存面板按取消结束。
    public func close() {
        dismiss(restoringFocus: false, animated: false)
    }

    private func dismiss(restoringFocus: Bool, animated: Bool) {
        guard var presentation else { return }
        self.presentation = nil
        presentation.observers.removeAll()
        let panel = presentation.panel
        panel.onRequestClose = {}
        if let sheet = panel.attachedSheet {
            panel.endSheet(sheet, returnCode: .cancel)
        }
        panel.ignoresMouseEvents = true
        let parent = presentation.parent
        parent?.removeChildWindow(panel)
        if restoringFocus {
            parent?.makeKey()
            presentation.request.restoreFocus()
        }
        guard animated, Self.animates, panel.isVisible else {
            Self.tearDown(panel)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { Self.tearDown(panel) }
        }
    }

    /// 隐藏面板并拆掉宿主视图：SwiftUI 的 `.task` 随之取消在途原图加载，本次预览持有的原图一起释放。
    private static func tearDown(_ panel: NativeCommentImagePreviewPanel) {
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private static var animates: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// 承载评论图片预览的子窗口面板：铺满父窗口、透明底（暗底由预览内容自己画），点暗底、Esc 或 ⌘W 关闭。
///
/// 用 AppKit 面板而不是 SwiftUI overlay、sheet 或 Quick Look：见 docs/ARCHITECTURE.md「原生 AppKit 集合视图」。
/// 刻意带标题栏（透明、隐藏标题与三个按钮）而不是无边框：AppKit 没有公开的窗口圆角半径，带标题栏的窗口由
/// 系统给出与父窗口一致的圆角，无边框面板铺满父窗口会在四角露出方角。不可移动、不在 App 失活时隐藏、可进入
/// 父窗口所在的全屏空间。只拥有关闭回调，关闭顺序由 `NativeCommentImagePreviewPresenter` 决定。
@MainActor
final class NativeCommentImagePreviewPanel: NSPanel {
    /// 用户要求关闭（⌘W、未被预览内容处理的 Esc，以及预览内容的关闭按钮与点暗底）；由 presenter 设置。
    var onRequestClose: () -> Void = {}

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = VideoDetailFeatureStrings.localized("评论图片预览")
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
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
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 面板必须与父窗口完全重合：带标题栏的窗口默认被 AppKit 推回可见区域（避开程序坞、屏幕边缘），父窗口
    /// 部分在屏幕外时面板会错位。
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// ⌘W 关闭预览，而不是关闭面板本身或越过它关掉主窗口。
    override func performClose(_ sender: Any?) {
        onRequestClose()
    }

    /// 预览内容没有处理 Esc（例如焦点不在预览表面上）时，同样关闭预览。
    override func cancelOperation(_ sender: Any?) {
        onRequestClose()
    }
}
