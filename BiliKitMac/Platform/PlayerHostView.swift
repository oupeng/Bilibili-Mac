import AVKit
import BiliApplication
import BiliBrowseFeature
import BiliDanmaku
import BiliModels
import BiliPlayback
import SwiftUI

/// 把唯一 `AVPlayer` 宿主与弹幕 overlay 组合为稳定的播放 surface。
///
/// 响应式页面可以重排这个 View，但不应创建第二个 player host；AppKit host 的销毁会
/// 主动断开 player 并释放弹幕 surface ownership。
struct PlayerHostView: View {
    @State private var previewEndedNotice: String?
    let player: AVPlayer
    let danmakuRenderer: CoreAnimationDanmakuRenderer
    let danmakuController: DanmakuPresentationController
    let videoModel: VideoViewModel?
    let sponsorBlockController: SponsorBlockController?
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)?

    init(
        player: AVPlayer,
        danmakuRenderer: CoreAnimationDanmakuRenderer,
        danmakuController: DanmakuPresentationController,
        videoModel: VideoViewModel? = nil,
        sponsorBlockController: SponsorBlockController? = nil,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)? = nil,
        endMomentaryPlaybackRate: ((UUID) -> Void)? = nil,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil,
        timelineUpdates: (() -> AsyncStream<PlaybackTimelineSnapshot>)? = nil
    ) {
        self.player = player
        self.danmakuRenderer = danmakuRenderer
        self.danmakuController = danmakuController
        self.videoModel = videoModel
        self.sponsorBlockController = sponsorBlockController
        self.beginMomentaryPlaybackRate = beginMomentaryPlaybackRate
        self.endMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        self.timelineUpdates = timelineUpdates
    }

    var body: some View {
        AVPlayerContainerView(
            player: player,
            renderer: danmakuRenderer,
            controller: danmakuController,
            blocksNativePlaybackInteraction: blocksNativePlaybackInteraction,
            resumeNotice: videoModel?.resumeNotice,
            previewEndedNotice: previewEndedNotice,
            restartFromBeginning: { videoModel?.restartFromBeginning() },
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles,
            focusIdentity: videoModel?.presentedBVID,
            sponsorBlockController: sponsorBlockController
        )
        .task(id: previewProjectionIdentity) {
            previewEndedNotice = nil
            guard let timelineUpdates,
                let context = videoModel?.presentedContext
            else { return }
            let identity = PlaybackItemIdentity(
                bvid: context.detail.bvid,
                cid: context.selectedPage.cid
            )
            for await snapshot in timelineUpdates() {
                guard !Task.isCancelled else { return }
                previewEndedNotice =
                    PlaybackPreviewEndPolicy.shouldPresentNotice(
                        accessNotice: context.accessNotice,
                        expectedIdentity: identity,
                        timeline: snapshot
                    )
                    ? AppStrings.localized(
                        "试看已结束，此视频为充电专属，BiliKit 暂不提供充电操作。"
                    ) : nil
            }
        }
    }

    private var blocksNativePlaybackInteraction: Bool {
        guard let videoModel else { return false }
        return switch videoModel.state {
        case .loading, .loadingPage, .preparingPlayback:
            true
        case .idle, .ready, .failed, .failedPage:
            false
        }
    }

    private var previewProjectionIdentity: String? {
        guard let context = videoModel?.presentedContext else { return nil }
        return
            "\(context.detail.bvid):\(context.selectedPage.cid):\(String(describing: context.accessNotice))"
    }
}

private struct AVPlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let renderer: CoreAnimationDanmakuRenderer
    let controller: DanmakuPresentationController
    let blocksNativePlaybackInteraction: Bool
    let resumeNotice: PlaybackResumeNotice?
    let previewEndedNotice: String?
    let restartFromBeginning: () -> Void
    let beginMomentaryPlaybackRate: ((Float) -> UUID?)?
    let endMomentaryPlaybackRate: ((UUID) -> Void)?
    let seekByTransportOffset: ((Double) -> Bool)?
    let adjustVolume: ((Float) -> Float)?
    let togglePlayback: (() -> Bool?)?
    let toggleDanmaku: (() -> Bool)?
    let toggleSubtitles: (() async -> NativeSubtitleToggleResult)?
    let focusIdentity: String?
    let sponsorBlockController: SponsorBlockController?

    func makeNSView(context: Context) -> DanmakuPlayerView {
        let view = DanmakuPlayerView(
            renderer: renderer,
            controller: controller,
            beginMomentaryPlaybackRate: beginMomentaryPlaybackRate,
            endMomentaryPlaybackRate: endMomentaryPlaybackRate,
            seekByTransportOffset: seekByTransportOffset,
            adjustVolume: adjustVolume,
            togglePlayback: togglePlayback,
            toggleDanmaku: toggleDanmaku,
            toggleSubtitles: toggleSubtitles
        )
        view.player = player
        view.startObservingPlayerItemChanges()
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
        view.startObservingSponsorBlockEvents(sponsorBlockController)
        return view
    }

    func updateNSView(_ view: DanmakuPlayerView, context: Context) {
        view.setPlaybackPreparationBlocked(blocksNativePlaybackInteraction)
        view.requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        view.finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        view.seekByTransportOffset = seekByTransportOffset
        view.adjustVolume = adjustVolume
        view.togglePlayback = togglePlayback
        view.toggleDanmaku = toggleDanmaku
        view.toggleSubtitles = toggleSubtitles
        view.setResumeNotice(
            resumeNotice,
            restartFromBeginning: restartFromBeginning
        )
        view.setPreviewEndedNotice(previewEndedNotice)
        view.requestInitialKeyboardFocus(for: focusIdentity)
        view.startObservingSponsorBlockEvents(sponsorBlockController)
        if view.player !== player {
            view.cancelMomentaryPlaybackRate()
            view.player = player
            view.startObservingPlayerItemChanges()
        }
    }

    /// 在 SwiftUI 销毁宿主时先撤销弹幕 surface，再断开 AVPlayer，避免旧 host 继续呈现。
    static func dismantleNSView(
        _ view: DanmakuPlayerView,
        coordinator: ()
    ) {
        view.setResumeNotice(nil, restartFromBeginning: {})
        view.setPreviewEndedNotice(nil)
        view.danmakuOverlay.detachSurface()
        view.stopObservingFocusLoss()
        view.stopObservingPlayerItemChanges()
        view.stopKeyboardMonitoring()
        view.cancelMomentaryPlaybackRate()
        view.player = nil
    }
}

enum PlayerPlaybackPreparationPolicy {
    static func controlsStyle(
        blocksNativePlaybackInteraction: Bool
    ) -> AVPlayerViewControlsStyle {
        blocksNativePlaybackInteraction ? .none : .default
    }
}

@MainActor
final class DanmakuPlayerView: AVPlayerView {
    let danmakuOverlay: DanmakuOverlayView
    private let keyboardShortcuts = PlayerKeyboardShortcutController()
    private let overlayModel = PlayerOverlayModel()
    private let overlayHostingView: PassthroughHostingView<PlayerOverlayView>
    private var installedDanmakuOverlay = false
    private var isPresentingFullScreen = false
    private var momentaryRateSessionID: UUID?
    private var momentaryRatePressID: UUID?
    private weak var observedPlayer: AVPlayer?
    private var playerItemObservation: NSKeyValueObservation?
    private var playerTimeControlObservation: NSKeyValueObservation?
    private var playerItemTimeJumpObservers = NativeVideoNotificationObservers()
    private var blocksNativePlaybackInteraction = false
    private var lastInitialFocusIdentity: String?
    private var pendingInitialFocusIdentity: String?
    private var focusLossObservers = NativeVideoNotificationObservers()
    private var sponsorBlockTask: Task<Void, Never>?
    private weak var observedSponsorBlockController: SponsorBlockController?
    var requestMomentaryPlaybackRate: ((Float) -> UUID?)?
    var finishMomentaryPlaybackRate: ((UUID) -> Void)?
    var seekByTransportOffset: ((Double) -> Bool)?
    var adjustVolume: ((Float) -> Float)?
    var togglePlayback: (() -> Bool?)?
    var toggleDanmaku: (() -> Bool)?
    var toggleSubtitles: (() async -> NativeSubtitleToggleResult)?

    init(
        renderer: CoreAnimationDanmakuRenderer,
        controller: DanmakuPresentationController,
        beginMomentaryPlaybackRate: ((Float) -> UUID?)?,
        endMomentaryPlaybackRate: ((UUID) -> Void)?,
        seekByTransportOffset: ((Double) -> Bool)? = nil,
        adjustVolume: ((Float) -> Float)? = nil,
        togglePlayback: (() -> Bool?)? = nil,
        toggleDanmaku: (() -> Bool)? = nil,
        toggleSubtitles: (() async -> NativeSubtitleToggleResult)? = nil
    ) {
        danmakuOverlay = DanmakuOverlayView(
            renderer: renderer,
            controller: controller
        )
        requestMomentaryPlaybackRate = beginMomentaryPlaybackRate
        finishMomentaryPlaybackRate = endMomentaryPlaybackRate
        self.seekByTransportOffset = seekByTransportOffset
        self.adjustVolume = adjustVolume
        self.togglePlayback = togglePlayback
        self.toggleDanmaku = toggleDanmaku
        self.toggleSubtitles = toggleSubtitles
        overlayHostingView = PassthroughHostingView(
            rootView: PlayerOverlayView(model: overlayModel)
        )
        super.init(frame: .zero)
        delegate = self
        updatesNowPlayingInfoCenter = false
        overlayHostingView.sizingOptions = []
        // 浮层与 content overlay 等大；不按窗口安全区缩进，否则播放器滚到工具栏下或全屏时提示位置
        // 与“从头播放”的点击区域会偏移。
        overlayHostingView.safeAreaRegions = []
        overlayHostingView.interactiveFrame = { [overlayModel] in
            overlayModel.interactiveFrame
        }
        keyboardShortcuts.feedbackPresenter = overlayModel
        keyboardShortcuts.onKeyboardMomentaryRateBegan = {
            [weak self] rate, pressID in
            self?.beginMomentaryPlaybackRate(rate, pressID: pressID)
        }
        keyboardShortcuts.onKeyboardMomentaryRateEnded = {
            [weak self] pressID in
            self?.endMomentaryPlaybackRate(ifPressID: pressID)
        }
        keyboardShortcuts.onRelativeSeek = { [weak self] offset in
            self?.seekByTransportOffset?(offset) ?? false
        }
        keyboardShortcuts.onVolumeStep = { [weak self] offset in
            self?.adjustVolume?(offset)
        }
        keyboardShortcuts.onTogglePlayback = { [weak self] in
            guard let togglePlayback = self?.togglePlayback else { return nil }
            return togglePlayback()
        }
        keyboardShortcuts.onToggleDanmaku = { [weak self] in
            self?.toggleDanmaku?()
        }
        keyboardShortcuts.onToggleSubtitles = { [weak self] in
            guard let toggleSubtitles = self?.toggleSubtitles else {
                return .unavailable
            }
            return await toggleSubtitles()
        }
        keyboardShortcuts.onToggleFullScreen = { [weak self] in
            self?.toggleFullScreen()
        }
        installDanmakuOverlayIfNeeded()
    }

    /// F 键切换 AVKit 全屏，与控制条全屏按钮走同一路径。
    ///
    /// AVKit 没有公开进入／退出全屏的方法；`enterFullScreen:`／`exitFullScreen:` 是本项目唯一使用的
    /// 私有 AVKit 接口。先确认响应再调用：系统移除后按 F 静默无效，全屏按钮不受影响。
    /// 是否处于全屏由公开的 `AVPlayerViewDelegate` 回调记录，不读私有状态。
    func toggleFullScreen() {
        guard showsFullScreenToggleButton, !blocksNativePlaybackInteraction else { return }
        let selector = NSSelectorFromString(
            isPresentingFullScreen ? "exitFullScreen:" : "enterFullScreen:"
        )
        guard responds(to: selector) else { return }
        perform(selector, with: nil)
    }

    override var acceptsFirstResponder: Bool {
        !blocksNativePlaybackInteraction
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !blocksNativePlaybackInteraction else { return nil }
        return super.hitTest(point)
    }

    func setPlaybackPreparationBlocked(_ blocked: Bool) {
        let stateChanged = blocksNativePlaybackInteraction != blocked
        blocksNativePlaybackInteraction = blocked
        controlsStyle = PlayerPlaybackPreparationPolicy.controlsStyle(
            blocksNativePlaybackInteraction: blocked
        )
        setAccessibilityHidden(blocked)
        keyboardShortcuts.setKeyboardInputEnabled(!blocked)
        guard stateChanged else {
            if !blocked {
                applyPendingInitialKeyboardFocus()
            }
            return
        }
        if blocked {
            cancelMomentaryPlaybackRate()
        }
        if !blocked {
            applyPendingInitialKeyboardFocus()
        }
        guard blocked,
            let window,
            let responderView = window.firstResponder as? NSView,
            responderView === self || responderView.isDescendant(of: self)
        else { return }
        window.makeFirstResponder(nil)
    }

    func setResumeNotice(
        _ notice: PlaybackResumeNotice?,
        restartFromBeginning: @escaping () -> Void
    ) {
        overlayModel.setResumeNotice(notice, restartFromBeginning: restartFromBeginning)
    }

    func setPreviewEndedNotice(_ message: String?) {
        overlayModel.setPreviewEndedMessage(message)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            stopObservingFocusLoss()
            cancelMomentaryPlaybackRate()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installDanmakuOverlayIfNeeded()
        startObservingFocusLoss()
        applyPendingInitialKeyboardFocus()
    }

    func startObservingSponsorBlockEvents(_ controller: SponsorBlockController?) {
        guard observedSponsorBlockController !== controller else { return }
        sponsorBlockTask?.cancel()
        observedSponsorBlockController = controller
        guard let controller else { return }

        sponsorBlockTask = Task { [weak self, weak controller] in
            guard let controller else { return }
            for await event in controller.skipEvents() {
                guard !Task.isCancelled, let self else { return }
                let categoryName = event.segment.category.displayName
                self.overlayModel.showFeedback(.sponsorBlockSkipped(category: categoryName))
            }
        }
    }

    func requestInitialKeyboardFocus(for identity: String?) {
        guard let identity, identity != lastInitialFocusIdentity else { return }
        pendingInitialFocusIdentity = identity
        applyPendingInitialKeyboardFocus()
    }

    private func applyPendingInitialKeyboardFocus() {
        guard !blocksNativePlaybackInteraction,
            let identity = pendingInitialFocusIdentity,
            let window
        else { return }
        pendingInitialFocusIdentity = nil
        lastInitialFocusIdentity = identity
        // 播放就绪时评论图片预览可能已打开；不抢走它的焦点，否则 Esc 与方向键会失效。
        guard
            !PlayerKeyboardShortcutController.focusOwnerHoldsFocus(
                window.firstResponder
            )
        else { return }
        window.makeFirstResponder(self)
    }

    func cancelMomentaryPlaybackRate() {
        keyboardShortcuts.cancelInputSession()
        if momentaryRateSessionID != nil {
            endMomentaryPlaybackRate()
        }
    }

    func startObservingPlayerItemChanges() {
        guard observedPlayer !== player else { return }
        stopObservingPlayerItemChanges()
        guard let player else { return }
        observedPlayer = player
        playerItemObservation = player.observe(\.currentItem, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor in
                self?.cancelMomentaryPlaybackRate()
                self?.overlayModel.clearResumeNotice(markDismissed: true)
                self?.startObservingCurrentItemTimeJumps()
            }
        }
        playerTimeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) {
            [weak self] _, change in
            guard change.newValue == .paused else { return }
            Task { @MainActor in
                self?.cancelMomentaryPlaybackRate()
            }
        }
        startObservingCurrentItemTimeJumps()
    }

    private func startObservingCurrentItemTimeJumps() {
        playerItemTimeJumpObservers.removeAll()
        guard let item = player?.currentItem else { return }
        playerItemTimeJumpObservers.observe(
            AVPlayerItem.timeJumpedNotification,
            object: item
        ) { [weak self] in
            guard let self, let player = self.player, player.currentItem != nil
            else { return }
            self.overlayModel.observeTimeJump(toSeconds: player.currentTime().seconds)
        }
    }

    func stopObservingPlayerItemChanges() {
        playerItemObservation?.invalidate()
        playerItemObservation = nil
        playerTimeControlObservation?.invalidate()
        playerTimeControlObservation = nil
        playerItemTimeJumpObservers.removeAll()
        observedPlayer = nil
    }

    private func installDanmakuOverlayIfNeeded() {
        guard !installedDanmakuOverlay,
            let contentOverlayView
        else {
            return
        }
        installedDanmakuOverlay = true
        danmakuOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(danmakuOverlay)
        // 快捷键以弹幕层所在窗口为准：AVKit detached 全屏只携带 content overlay，弹幕层随之移动。
        keyboardShortcuts.anchorView = danmakuOverlay
        keyboardShortcuts.startMonitoring()
        overlayHostingView.translatesAutoresizingMaskIntoConstraints = false
        contentOverlayView.addSubview(
            overlayHostingView,
            positioned: .above,
            relativeTo: danmakuOverlay
        )
        NSLayoutConstraint.activate([
            overlayHostingView.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            overlayHostingView.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            overlayHostingView.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            overlayHostingView.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            ),
            danmakuOverlay.leadingAnchor.constraint(
                equalTo: contentOverlayView.leadingAnchor
            ),
            danmakuOverlay.trailingAnchor.constraint(
                equalTo: contentOverlayView.trailingAnchor
            ),
            danmakuOverlay.topAnchor.constraint(
                equalTo: contentOverlayView.topAnchor
            ),
            danmakuOverlay.bottomAnchor.constraint(
                equalTo: contentOverlayView.bottomAnchor
            )
        ])
    }

    private func beginMomentaryPlaybackRate(
        _ rate: PlayerMomentaryRate,
        pressID: UUID
    ) {
        if momentaryRatePressID != pressID {
            endMomentaryPlaybackRate()
        }
        guard let player,
            let item = player.currentItem,
            item.status == .readyToPlay,
            player.rate > 0,
            let sessionID = requestMomentaryPlaybackRate?(rate.rawValue)
        else {
            clearMomentaryPlaybackRate()
            return
        }
        momentaryRateSessionID = sessionID
        momentaryRatePressID = pressID
        overlayModel.showMomentaryRate(rate)
    }

    private func endMomentaryPlaybackRate(ifPressID pressID: UUID) {
        guard momentaryRatePressID == pressID else { return }
        endMomentaryPlaybackRate()
    }

    private func endMomentaryPlaybackRate() {
        if let momentaryRateSessionID {
            finishMomentaryPlaybackRate?(momentaryRateSessionID)
        }
        clearMomentaryPlaybackRate()
    }

    private func clearMomentaryPlaybackRate() {
        momentaryRateSessionID = nil
        momentaryRatePressID = nil
        overlayModel.endMomentaryRate()
    }

    /// App 失活或任一窗口失去 key 时结束长按临时倍速。
    ///
    /// 不只观察宿主所在窗口：detached 全屏时按键发生在 AVKit 的全屏窗口里。长按要求持续按住，
    /// 窗口焦点一变这次长按就应结束，因此不区分是哪个窗口。
    private func startObservingFocusLoss() {
        focusLossObservers.removeAll()
        guard requestMomentaryPlaybackRate != nil,
            finishMomentaryPlaybackRate != nil,
            window != nil
        else {
            return
        }
        focusLossObservers.observe(
            NSApplication.didResignActiveNotification,
            object: nil
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
        focusLossObservers.observe(
            NSWindow.didResignKeyNotification,
            object: nil
        ) { [weak self] in
            self?.cancelMomentaryPlaybackRate()
        }
    }

    func stopObservingFocusLoss() {
        focusLossObservers.removeAll()
    }

    func stopKeyboardMonitoring() {
        keyboardShortcuts.cancelInputSession()
        keyboardShortcuts.stopMonitoring()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

extension DanmakuPlayerView: AVPlayerViewDelegate {
    func playerViewWillEnterFullScreen(_ playerView: AVPlayerView) {
        isPresentingFullScreen = true
    }

    func playerViewWillExitFullScreen(_ playerView: AVPlayerView) {
        isPresentingFullScreen = false
    }
}
