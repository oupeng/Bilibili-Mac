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
/// 从不绘制。暂停时增删弹幕 layer 由系统照常合成，不需要主动请求重新合成。
@MainActor
final class DanmakuOverlayView: NSView {
    private let renderer: CoreAnimationDanmakuRenderer
    private let controller: DanmakuPresentationController
    /// 按播放 item 时间运行的父层；renderer 的 `rootLayer` 在 surface 接管期间挂在它下面。
    private let synchronizedLayer = AVSynchronizedLayer()
    private let ownerID = UUID()
    private var previousSize: CGSize?
    private var previousBackingScale: CGFloat?
    private var isSurfaceAttached = false

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
        if window != nil {
            attachSurfaceIfNeeded()
        }
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

    /// 仅由当前 surface owner 发布布局尺寸；呈现控制器去抖后按新尺寸整张重排，并在一次提交里瞬时替换整屏。
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
        if controller.detachSurface(ownerID: ownerID),
            renderer.rootLayer.superlayer === synchronizedLayer
        {
            renderer.rootLayer.removeFromSuperlayer()
        }
    }

    private func attachSurfaceIfNeeded() {
        guard !isSurfaceAttached else { return }
        isSurfaceAttached = true
        controller.attachSurface(ownerID: ownerID)
        synchronizedLayer.addSublayer(renderer.rootLayer)
        previousSize = nil
        previousBackingScale = nil
        updateSurfaceIfNeeded()
    }
}
