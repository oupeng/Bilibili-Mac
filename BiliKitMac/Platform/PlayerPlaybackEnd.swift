import BiliApplication
import BiliVideoDetailFeature
import Foundation

/// 「播放结束后」偏好（`PlaybackEndBehavior`）的 `UserDefaults` 存取；持久化范围见 SECURITY-MODEL §6。
///
/// 设备级、所有窗口共用：读取时取此刻的值，不缓存，一个窗口改了，其他窗口下一次播完就按新值处理。只接受已知的原始值，
/// 缺失或损坏时回退默认（不循环）。只在主线程使用。
struct PlaybackEndBehaviorStore {
    private static let key = "player.endBehavior"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var behavior: PlaybackEndBehavior {
        get {
            defaults.string(forKey: Self.key).flatMap(PlaybackEndBehavior.init(rawValue:))
                ?? .defaultValue
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }
}

/// 播完时的处理：订阅播放时间线，交给视频模型按偏好处理，返回要在播放器上显示的提示。
///
/// 由 `WindowAdapters` 的播放器内容用播放引擎与视频模型构造（`make`），交给 `PlayerPlaybackEndObserver`。不持有状态。
struct PlayerPlaybackEndActions {
    typealias Observer = @MainActor (PlaybackTimelineSnapshot) -> Void
    typealias Observing = @MainActor (@escaping Observer) -> @MainActor @Sendable () -> Void

    /// 订阅时间线，返回取消订阅的函数。
    ///
    /// 订阅当下先收到一次当前快照（`PlaybackTimeline.observe`）。
    let observeTimeline: Observing
    /// 刚进入 `ended` 的快照；处理完给出提示，没有动作时为 nil。
    let handleEnded: @MainActor (PlaybackTimelineSnapshot) async -> PlayerActionFeedback?

    /// 重播失败时，只有播放器仍停在这一项的结尾才提示：期间用户另有操作或换了项，失败是预期内的，不打扰。
    @MainActor
    static func make(
        videoModel: VideoViewModel,
        observeTimeline: @escaping Observing,
        currentTimeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        store: PlaybackEndBehaviorStore
    ) -> Self {
        Self(
            observeTimeline: observeTimeline,
            handleEnded: { snapshot in
                let behavior = store.behavior
                switch await videoModel.handlePlaybackEnded(snapshot, behavior: behavior) {
                case .none:
                    return nil
                case .replayed:
                    return .endBehavior(behavior)
                case .replayFailed:
                    let current = currentTimeline()
                    return current.state == .ended && current.loadIntent == snapshot.loadIntent
                        ? .replayFailed : nil
                }
            }
        )
    }
}

/// 在时间线刚进入 `ended` 的那一刻按偏好处理一次。
///
/// 只认边沿：同一个 item（按 load intent 区分）从别的状态变成 `ended` 才触发，订阅当下补发的当前快照只作起点。
/// 所以用户在已播完时才改偏好、宿主重建、或时间线重复发布 `ended` 都不会触发；不能用只保留最新值、订阅时补发的
/// `timelineUpdates()`，那样会把已经结束的快照当成新的结束。是否真的动作、作用于哪一项由 `VideoViewModel` 再核对。
///
/// 由 `NativePlayerHostView` 持有：宿主创建时 `start`，拆除时 `stop`（先取消订阅，再取消在途的处理）。订阅期间时间线
/// 经回调强持有视频模型，而视频模型持有引擎，宿主拆除时必须 `stop` 才断开这个环。处理用一个 Task，新的结束到来时
/// 取消旧的；Task 只弱引用本类型，在主线程运行。取消只拦住提示，拦不住已经发给引擎的重播：引擎自己按 item、意图与
/// 用户操作作废过期的回到开头。
@MainActor
final class PlayerPlaybackEndObserver {
    private var cancelObservation: (@MainActor @Sendable () -> Void)?
    private var handling: Task<Void, Never>?
    /// 上一个快照的 item 与状态，用来认出“刚进入 ended”。
    private var lastIntent: PlaybackLoadIntent?
    private var lastState: PlaybackTimelineState?
    private var isBaselineSet = false

    /// 开始订阅，`present` 显示处理后的提示。
    ///
    /// 已在订阅时什么都不做。
    func start(
        _ actions: PlayerPlaybackEndActions,
        present: @escaping @MainActor (PlayerActionFeedback) -> Void
    ) {
        guard cancelObservation == nil else { return }
        isBaselineSet = false
        cancelObservation = actions.observeTimeline { [weak self] snapshot in
            guard let self, self.entersEnded(snapshot) else { return }
            self.handling?.cancel()
            self.handling = Task { [weak self] in
                guard let feedback = await actions.handleEnded(snapshot),
                    self != nil, !Task.isCancelled
                else { return }
                present(feedback)
            }
        }
    }

    func stop() {
        cancelObservation?()
        cancelObservation = nil
        handling?.cancel()
        handling = nil
    }

    private func entersEnded(_ snapshot: PlaybackTimelineSnapshot) -> Bool {
        defer {
            lastIntent = snapshot.loadIntent
            lastState = snapshot.state
            isBaselineSet = true
        }
        guard isBaselineSet, snapshot.state == .ended else { return false }
        return lastIntent != snapshot.loadIntent || lastState != .ended
    }
}
