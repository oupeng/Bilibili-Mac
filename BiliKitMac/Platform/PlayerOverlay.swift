import AVFoundation
import BiliApplication
import BiliPlayback
import BiliUI
import BiliVideoDetailFeature
import SwiftUI

/// 长按左右键的临时倍速：左 0.5 倍、右 2 倍；`rawValue` 即交给播放器的速率。
enum PlayerMomentaryRate: Float, Equatable, Sendable {
    case slow = 0.5
    case fast = 2

    var label: String {
        switch self {
        case .slow: "0.5X"
        case .fast: "2X"
        }
    }

    var symbolName: String {
        switch self {
        case .slow: "backward.fill"
        case .fast: "forward.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .slow: AppStrings.localized("临时播放速度 0.5 倍")
        case .fast: AppStrings.localized("临时播放速度 2 倍")
        }
    }
}

/// 快捷键操作后在播放器顶部显示的反馈徽标内容：文字、SF Symbol 与 VoiceOver 文案。
enum PlayerShortcutFeedback: Equatable {
    case momentaryRate(PlayerMomentaryRate)
    case relativeSeek(Int)
    case volume(Int)
    case playback(Bool)
    case danmaku(Bool)
    case subtitles(NativeSubtitleToggleResult)

    var label: String {
        switch self {
        case .momentaryRate(let rate): rate.label
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("后退 \(-seconds) 秒")
                : AppStrings.localized("前进 \(seconds) 秒")
        case .volume(let percent): "\(percent)%"
        case .playback(let isPlaying):
            isPlaying ? AppStrings.localized("播放") : AppStrings.localized("暂停")
        case .danmaku(let enabled):
            enabled ? AppStrings.localized("弹幕 开") : AppStrings.localized("弹幕 关")
        case .subtitles(.enabled(let label)): AppStrings.localized("字幕 \(label)")
        case .subtitles(.disabled): AppStrings.localized("字幕 关")
        case .subtitles(.unavailable): AppStrings.localized("无可用字幕")
        }
    }

    var symbolName: String {
        switch self {
        case .momentaryRate(let rate): rate.symbolName
        case .relativeSeek(let seconds):
            seconds < 0 ? "gobackward.5" : "goforward.5"
        case .volume(let percent):
            percent == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .playback(let isPlaying):
            isPlaying ? "play.fill" : "pause.fill"
        case .danmaku(let enabled):
            enabled ? "text.bubble.fill" : "text.bubble"
        case .subtitles(.enabled): "captions.bubble.fill"
        case .subtitles(.disabled), .subtitles(.unavailable):
            "captions.bubble"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .momentaryRate(let rate): rate.accessibilityLabel
        case .relativeSeek(let seconds):
            seconds < 0
                ? AppStrings.localized("已后退 \(-seconds) 秒")
                : AppStrings.localized("已前进 \(seconds) 秒")
        case .volume(let percent): AppStrings.localized("播放器音量 \(percent)%")
        case .playback(let isPlaying):
            isPlaying ? AppStrings.localized("已开始播放") : AppStrings.localized("已暂停播放")
        case .danmaku(let enabled):
            enabled ? AppStrings.localized("弹幕已开启") : AppStrings.localized("弹幕已关闭")
        case .subtitles(.enabled(let label)): AppStrings.localized("字幕已开启，\(label)")
        case .subtitles(.disabled): AppStrings.localized("字幕已关闭")
        case .subtitles(.unavailable): AppStrings.localized("当前视频没有可用字幕")
        }
    }
}

/// 快捷键反馈徽标的自动消失时机。
///
/// `delay` 是显示多久后淡出，连续操作会生成新反馈并重新计时；调长更久遮挡画面，调短来不及看清。
enum PlayerShortcutFeedbackDismissalPolicy {
    static let delay: Duration = .milliseconds(800)
    static let fadeDuration: TimeInterval = 0.16
}

private struct PlayerShortcutFeedbackBadge: View {
    let feedback: PlayerShortcutFeedback

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.symbolName)
            Text(feedback.label)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.title3.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(PlayerGlassCapsuleBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(feedback.accessibilityLabel)
    }
}

private struct PlayerGlassCapsuleBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            fallbackBackground(content)
        }
    }

    private func fallbackBackground(_ content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.18), lineWidth: 0.5)
            }
    }
}

/// 开播后的缓冲卡顿：AVKit 此时不画任何指示，由浮层转圈。
///
/// 只认 AVPlayer 为减少卡顿而等待（`toMinimizeStalls`）；开播与 seek 时的短暂评估等待不算。
/// 卡住持续到 `presentationDelay` 才呈现，期间恢复播放则不出现，避免拖进度条时一闪。
enum PlayerStallPolicy {
    static let presentationDelay: Duration = .milliseconds(300)
    static let fadeDurationSeconds: TimeInterval = 0.2

    static func isStalled(
        isPreparing: Bool,
        isItemReady: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus,
        reasonForWaitingToPlay: AVPlayer.WaitingReason?
    ) -> Bool {
        !isPreparing
            && isItemReady
            && timeControlStatus == .waitingToPlayAtSpecifiedRate
            && reasonForWaitingToPlay == .toMinimizeStalls
    }
}

/// 播放器浮层相对 content overlay 的位置；底部留出原生控制条的高度。
enum PlayerOverlayLayout {
    static let edgeInset: CGFloat = 20
    static let bottomInset: CGFloat = 64
    /// 浮层命名坐标空间；非隔离常量，可在 `onGeometryChange` 的 Sendable 闭包中引用。
    static let coordinateSpace = "PlayerOverlay"
}

/// “从头播放”按钮的标题，按钮文字与 accessibility label 共用。
enum PlayerResumeNoticePresentation {
    static var title: String { AppStrings.localized("从头播放") }
}

/// “从头播放”提示的自动收起规则。
///
/// `delay` 是续播后提示保留的时长，到时淡出，同一次续播不再出现；调长更久遮挡画面，
/// 调短用户来不及点。
enum PlayerResumeNoticeDismissalPolicy {
    static let delay: Duration = .seconds(5)
    static let fadeDurationSeconds: TimeInterval = 0.2
    /// 时间跳转后离续播位置超过该秒数即视为用户已自行定位，收起“从头播放”。
    static let positionToleranceSeconds: Double = 0.5
}

private struct PlayerResumeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                PlayerResumeNoticePresentation.title,
                systemImage: "arrow.uturn.backward"
            )
            .fontWeight(.semibold)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .modifier(PlayerResumeButtonStyle())
        .accessibilityLabel(PlayerResumeNoticePresentation.title)
        .accessibilityHint(AppStrings.localized("将当前视频定位到开头并继续播放"))
    }
}

private struct PlayerResumeButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            fallback(content)
        }
    }

    private func fallback(_ content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .modifier(PlayerGlassCapsuleBackground())
    }
}

private struct PlayerPreviewEndedBadge: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "hourglass.bottomhalf.filled")
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.leading)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .modifier(PlayerGlassCapsuleBackground())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message)
    }
}

/// 默认不接收鼠标事件的浮层 hosting view。
///
/// `interactiveFrame` 返回本视图坐标（左上原点）中的可交互区域时，只有该区域照常命中 SwiftUI 内容；
/// 其余点击、拖动与悬停穿透给下方的 AVKit 视图。
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveFrame: () -> CGRect? = { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let frame = interactiveFrame(),
            frame.contains(convert(point, from: superview))
        else { return nil }
        return super.hitTest(point)
    }
}

/// 播放器 content overlay 上的全部临时提示：准备与缓冲转圈、快捷键反馈、“从头播放”按钮与试看结束徽章。
///
/// 自动消失的计时由 `PlayerOverlayView` 的 `.task(id:)` 持有；这里只保存状态与 identity 规则。
@MainActor
@Observable
final class PlayerOverlayModel {
    /// 一次反馈：每次显示都生成新的 `id`。
    ///
    /// 视图的消失计时以 `id` 为 `.task(id:)`，重复相同的操作也会重新计时；旧计时到时按 id
    /// 比对后忽略。
    struct Feedback: Equatable {
        let id = UUID()
        let content: PlayerShortcutFeedback
        /// 临时倍速在按住期间保持显示；其他反馈到时自动消失。
        let dismissesAutomatically: Bool
    }

    private(set) var feedback: Feedback?
    private(set) var resumeNotice: PlaybackResumeNotice?
    private(set) var previewEndedMessage: String?
    private(set) var showsPreparationActivity = false
    /// 当前这次卡顿的 identity，恢复后为 nil。
    ///
    /// 呈现计时以它为 `.task` id：恢复后又卡住时生成新 id，重新计时。
    private(set) var stallID: UUID?
    private(set) var showsStallActivity = false
    @ObservationIgnored private(set) var restartFromBeginning: () -> Void = {}
    @ObservationIgnored private var dismissedResumeToken: PlaybackResumeToken?
    @ObservationIgnored fileprivate var resumeButtonFrame: CGRect?

    /// 只有“从头播放”按钮接收鼠标；坐标为 overlay 根视图空间。
    var interactiveFrame: CGRect? {
        resumeNotice == nil ? nil : resumeButtonFrame
    }

    func showFeedback(_ content: PlayerShortcutFeedback) {
        feedback = Feedback(content: content, dismissesAutomatically: true)
    }

    func showMomentaryRate(_ rate: PlayerMomentaryRate) {
        feedback = Feedback(content: .momentaryRate(rate), dismissesAutomatically: false)
    }

    func endMomentaryRate() {
        guard case .momentaryRate = feedback?.content else { return }
        fadeOutFeedback()
    }

    func expireFeedback(id: UUID) {
        guard feedback?.id == id else { return }
        fadeOutFeedback()
    }

    func setResumeNotice(
        _ notice: PlaybackResumeNotice?,
        restartFromBeginning: @escaping () -> Void
    ) {
        self.restartFromBeginning = restartFromBeginning
        guard let notice else {
            clearResumeNotice(markDismissed: false)
            dismissedResumeToken = nil
            return
        }
        guard notice.token != dismissedResumeToken,
            notice.token != resumeNotice?.token
        else { return }
        resumeNotice = notice
    }

    /// 自动消失：淡出并记住 token，同一次续播不再出现。
    func expireResumeNotice(token: PlaybackResumeToken) {
        guard resumeNotice?.token == token else { return }
        withAnimation(
            .easeInOut(duration: PlayerResumeNoticeDismissalPolicy.fadeDurationSeconds)
        ) {
            clearResumeNotice(markDismissed: true)
        }
    }

    /// 播放项目时间跳转后离开续播位置即收起提示；位置未知时同样收起。
    func observeTimeJump(toSeconds seconds: Double) {
        guard let resumeNotice,
            !seconds.isFinite
                || abs(seconds - resumeNotice.positionSeconds)
                    > PlayerResumeNoticeDismissalPolicy.positionToleranceSeconds
        else { return }
        clearResumeNotice(markDismissed: true)
    }

    func clearResumeNotice(markDismissed: Bool) {
        if markDismissed {
            dismissedResumeToken = resumeNotice?.token
        }
        guard resumeNotice != nil else { return }
        resumeNotice = nil
    }

    /// 播放器阻塞期间（换视频、切分 P、准备播放）player 还没挂上 item 时补一个转圈；item 一挂上，
    /// 未就绪期间由 AVKit 自己的转圈接手，两者不同时出现。
    func setPreparationActivity(isPreparing: Bool, hasCurrentItem: Bool) {
        let shows = isPreparing && !hasCurrentItem
        guard showsPreparationActivity != shows else { return }
        showsPreparationActivity = shows
    }

    /// 恢复播放立即撤下转圈；进入卡顿只记录，呈现由视图在延迟后调用 `presentStall(id:)`。
    func setStalled(_ stalled: Bool) {
        guard (stallID != nil) != stalled else { return }
        stallID = stalled ? UUID() : nil
        guard !stalled, showsStallActivity else { return }
        withAnimation(.easeInOut(duration: PlayerStallPolicy.fadeDurationSeconds)) {
            showsStallActivity = false
        }
    }

    func presentStall(id: UUID) {
        guard stallID == id, !showsStallActivity else { return }
        withAnimation(.easeInOut(duration: PlayerStallPolicy.fadeDurationSeconds)) {
            showsStallActivity = true
        }
    }

    func setPreviewEndedMessage(_ message: String?) {
        guard previewEndedMessage != message else { return }
        previewEndedMessage = message
    }

    private func fadeOutFeedback() {
        withAnimation(.easeInOut(duration: PlayerShortcutFeedbackDismissalPolicy.fadeDuration)) {
            feedback = nil
        }
    }
}

/// 所有播放器浮层共用的一棵 SwiftUI 树，铺满 content overlay。
struct PlayerOverlayView: View {
    let model: PlayerOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .overlay { stallActivity }
            .overlay { preparationActivity }
            .overlay(alignment: .top) { feedbackBadge }
            .overlay(alignment: .bottomLeading) { resumeButton }
            .overlay(alignment: .bottom) { previewEndedBadge }
            .coordinateSpace(.named(PlayerOverlayLayout.coordinateSpace))
            .task(id: model.stallID) {
                guard let stallID = model.stallID else { return }
                try? await Task.sleep(for: PlayerStallPolicy.presentationDelay)
                guard !Task.isCancelled else { return }
                model.presentStall(id: stallID)
            }
    }

    @ViewBuilder
    private var stallActivity: some View {
        if model.showsStallActivity {
            PlayerLoadingIndicator()
                .accessibilityLabel(AppStrings.localized("正在缓冲"))
                .transition(reduceMotion ? .identity : .opacity)
        }
    }

    @ViewBuilder
    private var preparationActivity: some View {
        if model.showsPreparationActivity {
            PlayerLoadingIndicator()
                .accessibilityLabel(AppStrings.localized("正在准备播放"))
        }
    }

    @ViewBuilder
    private var feedbackBadge: some View {
        if let feedback = model.feedback {
            PlayerShortcutFeedbackBadge(feedback: feedback.content)
                .padding(.top, PlayerOverlayLayout.edgeInset)
                .transition(reduceMotion ? .identity : .opacity)
                .task(id: feedback.id) {
                    guard feedback.dismissesAutomatically else { return }
                    try? await Task.sleep(for: PlayerShortcutFeedbackDismissalPolicy.delay)
                    guard !Task.isCancelled else { return }
                    model.expireFeedback(id: feedback.id)
                }
        }
    }

    @ViewBuilder
    private var resumeButton: some View {
        if let notice = model.resumeNotice {
            PlayerResumeButton { model.restartFromBeginning() }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PlayerOverlayLayout.coordinateSpace))
                } action: { frame in
                    model.resumeButtonFrame = frame
                }
                .padding(.leading, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
                .transition(.opacity)
                .task(id: notice.token) {
                    try? await Task.sleep(for: PlayerResumeNoticeDismissalPolicy.delay)
                    guard !Task.isCancelled else { return }
                    model.expireResumeNotice(token: notice.token)
                }
        }
    }

    @ViewBuilder
    private var previewEndedBadge: some View {
        if let message = model.previewEndedMessage {
            PlayerPreviewEndedBadge(message: message)
                .padding(.horizontal, PlayerOverlayLayout.edgeInset)
                .padding(.bottom, PlayerOverlayLayout.bottomInset)
        }
    }
}
