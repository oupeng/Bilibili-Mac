import AVFoundation
import AppKit
import BiliDanmaku

/// 将 renderer 的 layer 挂到当前 `AVPlayerView` overlay 的同步 layer 下，并独占其尺寸更新权。
///
/// `ownerID` 防止已拆除 host 的迟到 layout/detach 清空新 host；零尺寸只表示 surface 尚未完成布局，
/// 不会扩大为另一个渲染会话。用 AppKit：弹幕由 Core Animation layer 树渲染，要作为 layer-backed
/// `NSView` 放进 `AVPlayerView` 的 content overlay，才能随 detached 全屏一起移动，见
/// docs/ARCHITECTURE.md「播放页布局」。不接收鼠标事件。
///
/// 弹幕的时间来自 `synchronizedLayer`（`AVSynchronizedLayer`）：它的子树按绑定的播放 item 的时间运行，
/// AVFoundation 在主线程上随 item timebase 的速率变化与时间跳变调整它，暂停、倍速、seek、缓冲停顿与
/// 播放结束都由它处理，renderer 的 `rootLayer` 挂在它下面。它不会跟随 `replaceCurrentItem` 自动换绑：
/// 播放器宿主在 `currentItem` 变化时调用 `bind(to:)`，先让呈现控制器清屏，再换绑，否则旧弹幕会在新
/// item 的时间线上错位。同步只在 layer 进入渲染上下文后才启动，overlay 在窗口里即可。
///
/// 这是 layer-backed 视图加自定义 layer（先 `wantsLayer` 再设 `layer`），不是 layer-hosting；视图本身
/// 从不绘制，AppKit 不会主动重绘它。暂停时视频不出新帧、同步 layer 的速率为 0，窗口可能停在一次
/// 没有完整合成的画面上，所以它作为 `DanmakuFrameScheduling` 为 renderer 提供下一显示帧：有请求时用
/// `displayLink(target:selector:)` 建一个 display link，回调一次即失效，不常驻。owner 是本视图；不可见
/// （不在窗口里、隐藏、窗口最小化或被完全遮挡）时不接受请求；停止点是离开窗口、变为不可见与交还
/// surface，停止时未回调的请求以 false 回调；恢复可见（取消隐藏、取消最小化、遮挡解除）时请 renderer
/// 再走一次 `recompositeIfStill`，补上不可见期间没完成的重新合成。renderer 另有时限兜底，到点会取消。
/// display link 持有
/// target，在途期间本视图不会释放，最多到下一帧、停止或 renderer 的时限为止。
@MainActor
final class DanmakuOverlayView: NSView, DanmakuFrameScheduling {
    private let renderer: CoreAnimationDanmakuRenderer
    private let controller: DanmakuPresentationController
    /// 按播放 item 时间运行的父层；renderer 的 `rootLayer` 在 surface 接管期间挂在它下面。
    private let synchronizedLayer = AVSynchronizedLayer()
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var previousBackingScale: CGFloat?
    private var isSurfaceAttached = false
    /// 只在有帧请求时存在的 display link；回调或停止时失效并置 nil。
    private var frameLink: CADisplayLink?
    private var frameHandlers: [@MainActor (Bool) -> Void] = []
    /// 正在监听可见性变化（遮挡、最小化）的窗口；换窗口或离开窗口时退订。
    private weak var observedWindow: NSWindow?

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController
    ) {
        self.renderer = renderer
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        // 尺寸随视图变化时不带隐式过渡。
        synchronizedLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        synchronizedLayer.anchorPoint = .zero
        layer?.addSublayer(synchronizedLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility(of: window)
        if window != nil {
            attachSurfaceIfNeeded()
        } else {
            cancelNextFrameRequests()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        cancelNextFrameRequests()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        recompositeIfDisplaying()
    }

    override func layout() {
        super.layout()
        synchronizedLayer.frame = bounds
        updateSurfaceIfNeeded()
    }

    /// 同步 layer 换绑到 `item`（nil 表示没有 item）；持有 surface 时先让呈现控制器清屏。
    ///
    /// 由播放器宿主在 `currentItem` 变化与开始观察 player 时调用；同一 item 重复调用是空操作。
    func bind(to item: AVPlayerItem?) {
        guard synchronizedLayer.playerItem !== item else { return }
        if isSurfaceAttached {
            controller.playerItemWillChange(ownerID: ownerID)
        }
        synchronizedLayer.playerItem = item
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// 仅由当前 surface owner 发布布局尺寸；已有弹幕保留运动，新弹幕使用最新尺寸。
    func updateSurfaceIfNeeded() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let backingScale =
            window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        guard
            bounds.size != previousSize
                || backingScale != previousBackingScale
        else {
            return
        }
        previousSize = bounds.size
        previousBackingScale = backingScale
        let width = max(Double(bounds.width), 0)
        let height = max(Double(bounds.height), 0)
        controller.updateSurface(
            width: width,
            height: height,
            backingScale: Double(backingScale),
            ownerID: ownerID
        )
    }

    /// 撤销当前 host 的 ownership；不是 owner 时不会触碰后来接管的 surface。
    func detachSurface() {
        guard isSurfaceAttached else { return }
        isSurfaceAttached = false
        cancelNextFrameRequests()
        if renderer.frameScheduler === self {
            renderer.frameScheduler = nil
        }
        if controller.detachSurface(ownerID: ownerID),
            renderer.rootLayer.superlayer === synchronizedLayer
        {
            renderer.rootLayer.removeFromSuperlayer()
        }
    }

    func requestNextFrame(_ handler: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard isSurfaceAttached, isDisplayingFrames else { return false }
        frameHandlers.append(handler)
        if frameLink == nil {
            let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
            link.add(to: .main, forMode: .common)
            frameLink = link
        }
        return true
    }

    func cancelNextFrameRequests() {
        finishFrameRequests(didDisplay: false)
    }

    /// 视图此刻能否出帧：在窗口里、没有被隐藏、窗口没有最小化且没有被完全遮挡。
    private var isDisplayingFrames: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, !window.isMiniaturized else {
            return false
        }
        return window.occlusionState.contains(.visible)
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        finishFrameRequests(didDisplay: true)
    }

    /// 先让 display link 失效、取走请求再回调：回调里可能再次请求下一帧，那会建一个新的。
    private func finishFrameRequests(didDisplay: Bool) {
        frameLink?.invalidate()
        frameLink = nil
        let handlers = frameHandlers
        frameHandlers.removeAll()
        for handler in handlers {
            handler(didDisplay)
        }
    }

    /// 只监听当前所在窗口的遮挡与最小化；变为不可见时像离开窗口一样停止 display link。
    private func observeVisibility(of window: NSWindow?) {
        guard observedWindow !== window else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            for name in Self.windowVisibilityNotifications {
                center.removeObserver(self, name: name, object: observedWindow)
            }
        }
        observedWindow = window
        guard let window else { return }
        for name in Self.windowVisibilityNotifications {
            center.addObserver(
                self,
                selector: #selector(windowVisibilityDidChange(_:)),
                name: name,
                object: window
            )
        }
    }

    /// 影响窗口能否出帧的通知：遮挡状态变化、最小化与取消最小化。
    private static let windowVisibilityNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification
    ]

    @objc private func windowVisibilityDidChange(_ notification: Notification) {
        if isDisplayingFrames {
            recompositeIfDisplaying()
        } else {
            cancelNextFrameRequests()
        }
    }

    /// 可见时请 renderer 补上没完成的重新合成；它只在静止且有未合成的改动时才请求下一帧。
    private func recompositeIfDisplaying() {
        guard isSurfaceAttached, isDisplayingFrames else { return }
        renderer.recompositeIfStill()
    }

    private func attachSurfaceIfNeeded() {
        guard !isSurfaceAttached else { return }
        isSurfaceAttached = true
        controller.attachSurface(ownerID: ownerID)
        renderer.frameScheduler = self
        synchronizedLayer.addSublayer(renderer.rootLayer)
        previousSize = nil
        previousBackingScale = nil
        updateSurfaceIfNeeded()
    }
}
