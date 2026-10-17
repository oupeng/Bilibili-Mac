import AppKit
import SwiftUI

/// 评论图片预览的缩放规则：倍率相对“适配可视区”计算，1 即适配。
enum NativeCommentImageZoomGeometry {
    /// 双指缩放的上限；先取保守值，按实际体验再调。
    static let maximumMagnification: CGFloat = 4
    /// 单击图片放大到的倍率。
    static let clickMagnification: CGFloat = 2
    /// 按下后移动超过这个距离（点）就当作拖动平移，不再当作单击。
    static let dragThreshold: CGFloat = 3
    private static let fitTolerance: CGFloat = 0.01

    /// 图片按比例缩进可视区后的尺寸；文档视图始终是这个尺寸，换成同比例的原图时缩放位置不变。
    static func fittedSize(imageSize: CGSize, in viewport: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
            viewport.width > 0, viewport.height > 0
        else { return .zero }
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return CGSize(
            width: floor(imageSize.width * scale),
            height: floor(imageSize.height * scale)
        )
    }

    /// 按下到当前位置移动超过阈值即为拖动，不再当作单击。
    static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) > dragThreshold
    }

    static func isFitted(_ magnification: CGFloat) -> Bool {
        magnification <= 1 + fitTolerance
    }

    /// 单击图片：适配时放大，已放大时回到适配。
    static func magnificationAfterClick(from magnification: CGFloat) -> CGFloat {
        isFitted(magnification) ? clickMagnification : 1
    }
}

/// 预览中的可缩放图片：触控板双指缩放与两指平移由 `NSScrollView` 原生提供。
///
/// SwiftUI 没有现成的“双指缩放 + 平移 + 回弹”滚动容器，所以只在图片这一块用 AppKit。单击图片在适配与
/// 放大之间切换，按住拖动平移；点图片以外的区域交给 `onDismissArea`（关闭预览）。视图不接收键盘焦点，
/// 方向键与 Esc 仍由外层预览处理。
struct NativeCommentImageZoomView: NSViewRepresentable {
    let image: CGImage
    /// 动图数据；有时逐帧替换图片内容，不改尺寸与缩放状态。
    let animation: NativeAnimatedImage?
    let accessibilityLabel: String
    let onDismissArea: () -> Void

    func makeNSView(context: Context) -> NativeCommentImageZoomScrollView {
        let view = NativeCommentImageZoomScrollView()
        update(view)
        return view
    }

    func updateNSView(_ view: NativeCommentImageZoomScrollView, context: Context) {
        update(view)
    }

    private func update(_ view: NativeCommentImageZoomScrollView) {
        view.setImage(image, animation: animation)
        view.onDismissArea = onDismissArea
        view.imageView.setAccessibilityLabel(accessibilityLabel)
    }
}

/// 图片区的 `NSScrollView`：持有图片文档视图与单击切换缩放的进行中目标，处理单击、拖动平移与点空白关闭。
///
/// 还拥有动图播放（`NativeAnimatedImagePlayback`，逐帧只换文档视图的图层内容）与对自己“双指缩放结束”通知的
/// 观察（selector 方式，随视图释放由系统移除）。用 AppKit 的理由见 `NativeCommentImageZoomView`。
@MainActor
final class NativeCommentImageZoomScrollView: NSScrollView {
    let imageView = NativeCommentImageZoomDocumentView()
    var onDismissArea: () -> Void = {}
    /// 单击切换动画进行中的目标倍率；动画期间 `magnification` 还是中间值，不能用来决定下一次切换。
    private var requestedMagnification: CGFloat?
    private var mouseDownLocation: CGPoint?

    init() {
        super.init(frame: .zero)
        contentView = NativeCommentImageZoomClipView()
        contentView.postsBoundsChangedNotifications = true
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = NativeCommentImageZoomGeometry.maximumMagnification
        documentView = imageView
        // 只把图片暴露给辅助功能，不多一层没有名字的滚动区域。
        setAccessibilityElement(false)
        imageView.onClick = { [weak self] point in self?.toggleZoom(at: point) }
        imageView.onDrag = { [weak self] delta in self?.pan(by: delta) }
        imageView.isZoomed = { [weak self] in self?.isZoomed ?? false }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveMagnifyDidEnd),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    var isZoomed: Bool {
        !NativeCommentImageZoomGeometry.isFitted(requestedMagnification ?? magnification)
    }

    /// 逐帧只替换图片层内容，不改文档视图尺寸与缩放状态；停下时换回第一帧。
    private lazy var playback = NativeAnimatedImagePlayback(
        host: imageView,
        onFrame: { [weak self] frame in self?.imageView.layer?.contents = frame },
        onRestoreFirstFrame: { [weak self] in
            guard let self else { return }
            self.imageView.layer?.contents = self.imageView.image
        }
    )

    func setImage(_ image: CGImage, animation: NativeAnimatedImage?) {
        if imageView.image !== image {
            imageView.image = image
            needsLayout = true
        }
        playback.play(animation)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        playback.hostVisibilityDidChange()
    }

    /// 文档视图始终是图片适配可视区（未缩放坐标）后的尺寸；可视区尺寸变化时重新适配，保留倍率与
    /// 可视中心在图片中的相对位置，避免改窗口大小或切全屏时画面跳动。
    override func layout() {
        super.layout()
        // 尺寸确定后才有可见区域：首次布局或窗口变大后重新判断能否播放动图。
        defer { playback.hostVisibilityDidChange() }
        guard let image = imageView.image else { return }
        let fitted = NativeCommentImageZoomGeometry.fittedSize(
            imageSize: CGSize(width: image.width, height: image.height),
            in: frame.size
        )
        let previous = imageView.frame.size
        guard previous != fitted else { return }
        let visible = contentView.bounds
        let relativeCenter =
            previous.width > 0 && previous.height > 0
            ? CGPoint(x: visible.midX / previous.width, y: visible.midY / previous.height)
            : CGPoint(x: 0.5, y: 0.5)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        let size = contentView.bounds.size
        let origin = CGPoint(
            x: relativeCenter.x * fitted.width - size.width / 2,
            y: relativeCenter.y * fitted.height - size.height / 2
        )
        contentView.scroll(
            to: contentView.constrainBoundsRect(CGRect(origin: origin, size: size)).origin
        )
        reflectScrolledClipView(contentView)
    }

    /// 两指双击与单击图片走同一切换，不用系统按内容推测的倍率。
    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: imageView.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
    }

    /// 在图片四周的空白处单击（没有拖动）时关闭预览。
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard let start = mouseDownLocation,
            !NativeCommentImageZoomGeometry.isDrag(from: start, to: event.locationInWindow)
        else { return }
        let point = imageView.convert(event.locationInWindow, from: nil)
        guard !imageView.bounds.contains(point) else { return }
        onDismissArea()
    }

    func toggleZoom(at point: CGPoint) {
        let target = NativeCommentImageZoomGeometry.magnificationAfterClick(
            from: requestedMagnification ?? magnification
        )
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            setMagnification(target, centeredAt: point)
            requestedMagnification = nil
        } else {
            requestedMagnification = target
            NSAnimationContext.runAnimationGroup { _ in
                animator().setMagnification(target, centeredAt: point)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.requestedMagnification == target else { return }
                    self.requestedMagnification = nil
                }
            }
        }
        imageView.zoomStateDidChange()
    }

    /// `delta` 是指针在窗口坐标（y 向上）中的位移；图片跟着指针走，所以可视区反向移动。
    private func pan(by delta: CGSize) {
        var origin = contentView.bounds.origin
        origin.x -= delta.width / magnification
        origin.y += delta.height / magnification
        contentView.scroll(
            to: contentView.constrainBoundsRect(
                CGRect(origin: origin, size: contentView.bounds.size)
            ).origin
        )
        reflectScrolledClipView(contentView)
    }

    @objc private func liveMagnifyDidEnd() {
        requestedMagnification = nil
        imageView.zoomStateDidChange()
    }
}

/// 图片比可视区小的方向上居中显示。
@MainActor
final class NativeCommentImageZoomClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentFrame = documentView?.frame else { return rect }
        if rect.width > documentFrame.width {
            rect.origin.x = (documentFrame.width - rect.width) / 2
        }
        if rect.height > documentFrame.height {
            rect.origin.y = (documentFrame.height - rect.height) / 2
        }
        return rect
    }
}

/// 以 layer 内容显示整张图片（缩放时按原图像素采样）；处理单击缩放、拖动平移与放大镜指针。
@MainActor
final class NativeCommentImageZoomDocumentView: NSView {
    var image: CGImage? {
        didSet { layer?.contents = image }
    }
    var onClick: (CGPoint) -> Void = { _ in }
    var onDrag: (CGSize) -> Void = { _ in }
    var isZoomed: () -> Bool = { false }

    private var mouseDownLocation: CGPoint?
    private var lastDragLocation: CGPoint?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = NativePlaybackCommentImageStyle.cornerRadius
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibilityActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    /// 指针随状态变化：适配时放大镜 +，放大时放大镜 −，拖动时抓手。
    ///
    /// 用光标区域而不是 push/pop，视图在拖动途中被移除（翻页、关闭）也不会在全局光标栈里留下抓手。
    override func resetCursorRects() {
        let cursor: NSCursor =
            isDragging ? .closedHand : (isZoomed() ? .zoomOut : .zoomIn)
        addCursorRect(bounds, cursor: cursor)
    }

    func zoomStateDidChange() {
        window?.invalidateCursorRects(for: self)
        updateAccessibilityActions()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        lastDragLocation = event.locationInWindow
        isDragging = false
    }

    /// 位移超过阈值后这次按下就不再算单击；只有放大时拖动才平移。
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let location = event.locationInWindow
        if !isDragging {
            guard NativeCommentImageZoomGeometry.isDrag(from: start, to: location) else { return }
            isDragging = true
            zoomStateDidChange()
        }
        guard isZoomed() else { return }
        let previous = lastDragLocation ?? location
        lastDragLocation = location
        onDrag(CGSize(width: location.x - previous.x, height: location.y - previous.y))
    }

    /// 双击的第二下不再切换：第一下已经放大（或还原）。
    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging
        defer {
            mouseDownLocation = nil
            lastDragLocation = nil
            isDragging = false
            if wasDragging { zoomStateDidChange() }
        }
        guard mouseDownLocation != nil, !wasDragging, event.clickCount <= 1 else { return }
        onClick(convert(event.locationInWindow, from: nil))
    }

    /// VoiceOver 没有指针手势：用自定义操作在适配与放大之间切换（以图片中心为准）。
    private func updateAccessibilityActions() {
        let name =
            isZoomed()
            ? VideoDetailFeatureStrings.localized("恢复适配大小")
            : VideoDetailFeatureStrings.localized("放大图片")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                self.onClick(CGPoint(x: self.bounds.midX, y: self.bounds.midY))
                return true
            }
        ])
    }
}
