import AVFoundation
import AppKit
import BiliDanmaku

/// 将 renderer 的 layer 挂到弹幕时钟层下，放进当前 `AVPlayerView` 的 content overlay，并独占其尺寸更新权。
///
/// `ownerID` 防止已拆除 host 的迟到 layout/detach 清空新 host；零尺寸只表示 surface 尚未完成布局，
/// 不会扩大为另一个渲染会话。用 AppKit：弹幕由 Core Animation layer 树渲染，要作为 layer-backed
/// `NSView` 放进 `AVPlayerView` 的 content overlay，才能随 detached 全屏一起移动，见
/// docs/ARCHITECTURE.md「播放页布局」。不接收鼠标事件。
///
/// 弹幕的时间来自 `clock`（`DanmakuTimebaseClock`）：时钟层的本地时间跟随绑定 item 的 timebase 时间，
/// 由 timebase 通知在后台队列上驱动，暂停、倍速、seek、缓冲停顿与播放结束都由它跟随，renderer 的
/// `rootLayer` 挂在它下面。它不会跟随 `replaceCurrentItem` 自动换绑：播放器宿主在 `currentItem` 变化时
/// 调用 `bind(to:)`，先让呈现控制器清屏，再换绑到新 item 的 timebase，否则旧弹幕会在新 item 的时间线上
/// 错位。本视图拥有时钟（释放时随之注销观察），并在主线程负责时钟层的 frame；时钟层的时间属性只由时钟
/// 自己的队列写。
///
/// 这是 layer-backed 视图加自定义 layer（先 `wantsLayer` 再设 `layer`），不是 layer-hosting；视图本身
/// 从不绘制。暂停时增删弹幕 layer 由系统照常合成，不需要主动请求重新合成。
///
/// 弹幕按承载窗口的屏幕尺寸规划（取景框模型，见 docs/ARCHITECTURE.md「弹幕」），所以除了自身尺寸与
/// backing scale，还要在窗口换屏、屏幕分辨率变化时重新发布屏幕尺寸。这两个通知的观察在进入窗口时
/// 登记、离开窗口时注销，由本视图持有；回调都在主线程。
@MainActor
final class DanmakuOverlayView: NSView {
    private let renderer: CoreAnimationDanmakuRenderer
    private let controller: DanmakuPresentationController
    /// 按绑定 item 的 timebase 运行的时钟；renderer 的 `rootLayer` 在 surface 接管期间挂在它的时钟层下。
    private let clock = DanmakuTimebaseClock()
    /// 当前绑定的 timebase，只用来让同一 timebase 的重复绑定成为空操作。
    private var boundTimebase: CMTimebase?
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var previousScreenSize: CGSize?
    private var previousBackingScale: CGFloat?
    private var isSurfaceAttached = false
    /// 是否已登记换屏与屏幕参数通知；进入窗口时登记一次，离开窗口时按名字整体注销，不依赖窗口引用。
    private var isObservingScreenChanges = false

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
        clock.layer.actions = ["bounds": NSNull(), "position": NSNull()]
        clock.layer.anchorPoint = .zero
        layer?.addSublayer(clock.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopObservingScreenChanges()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            startObservingScreenChanges(of: window)
            attachSurfaceIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        clock.layer.frame = bounds
        updateSurfaceIfNeeded()
    }

    /// 时钟换绑到 `item` 的 timebase（nil 表示没有 item）；持有 surface 时先让呈现控制器清屏。
    ///
    /// 由播放器宿主在 `currentItem` 变化、开始观察 player 与拆除时调用；同一 timebase 重复调用是空操作。
    /// `AVPlayerItem` 创建后 `timebase` 就不是 nil，换 item 之后是另一个对象，所以按 timebase 判断换绑。
    func bind(to item: AVPlayerItem?) {
        let timebase = item?.timebase
        guard boundTimebase !== timebase else { return }
        if isSurfaceAttached {
            controller.playerItemWillChange(ownerID: ownerID)
        }
        boundTimebase = timebase
        clock.bind(timebase)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// 仅由当前 surface owner 发布窗口尺寸、屏幕尺寸与 backing scale。
    ///
    /// 窗口尺寸变化只移动取景框；屏幕尺寸或 scale 变化时呈现控制器整张重排，并在一次提交里瞬时替换整屏。
    /// 屏幕取 `frame` 而不是 `visibleFrame`：全屏时画面覆盖整块屏幕，菜单栏与 Dock 不占位。不在窗口里时
    /// 不发布（拿不到承载它的屏幕，用别的屏幕会按错误的规划尺寸重排）；窗口完全在屏幕外时屏幕尺寸按 0
    /// 发布，规划尺寸退回窗口尺寸。
    func updateSurfaceIfNeeded() {
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        let backingScale = window.backingScaleFactor
        let screenSize = window.screen?.frame.size ?? .zero
        guard
            bounds.size != previousSize
                || screenSize != previousScreenSize
                || backingScale != previousBackingScale
        else {
            return
        }
        previousSize = bounds.size
        previousScreenSize = screenSize
        previousBackingScale = backingScale
        controller.updateSurface(
            width: max(Double(bounds.width), 0),
            height: max(Double(bounds.height), 0),
            screenWidth: Double(screenSize.width),
            screenHeight: Double(screenSize.height),
            backingScale: Double(backingScale),
            ownerID: ownerID
        )
    }

    /// 撤销当前 host 的 ownership；不是 owner 时不会触碰后来接管的 surface。
    func detachSurface() {
        guard isSurfaceAttached else { return }
        isSurfaceAttached = false
        if controller.detachSurface(ownerID: ownerID),
            renderer.rootLayer.superlayer === clock.layer
        {
            renderer.rootLayer.removeFromSuperlayer()
        }
    }

    /// 窗口换到另一块屏幕、或屏幕分辨率与排列变化时重新发布尺寸；backing scale 的变化另由
    /// `viewDidChangeBackingProperties` 覆盖，但同 scale 不同尺寸的屏幕只有这两个通知。
    private func startObservingScreenChanges(of window: NSWindow) {
        guard !isObservingScreenChanges else { return }
        isObservingScreenChanges = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// `object` 传 nil：注销本视图在这个名字下的全部登记，与当时登记的是哪个窗口无关。
    private func stopObservingScreenChanges() {
        guard isObservingScreenChanges else { return }
        isObservingScreenChanges = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenDidChange(_ notification: Notification) {
        updateSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !isSurfaceAttached else { return }
        isSurfaceAttached = true
        controller.attachSurface(ownerID: ownerID)
        clock.layer.addSublayer(renderer.rootLayer)
        previousSize = nil
        previousScreenSize = nil
        previousBackingScale = nil
        updateSurfaceIfNeeded()
    }
}
