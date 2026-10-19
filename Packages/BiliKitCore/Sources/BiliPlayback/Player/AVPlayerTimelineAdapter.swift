@preconcurrency import AVFoundation
import BiliApplication
import Foundation
import os

/// 把 AVPlayer/KVO/notification 事件投影为平台无关、identity-safe 的播放时间线。
///
/// 所有 callback 都同时核对当前 `AVPlayerItem` 与 item token；observer bag 在替换、失败和
/// clear 时统一释放，避免旧 item 继续推进弹幕、观看进度等时间线消费方。
///
/// 两套 seek 事实分开维护：`discontinuityGeneration` 由 engine 的 seek 收尾与 `AVPlayerItem` 的
/// time-jump 通知推进（观看进度、Now Playing 使用）；`seekPhase`／`landingGeneration` 只由 item
/// timebase 的 time-jump 通知经 `seekLandingTimer` 推进（弹幕使用），不看 engine 的 seek 记录。
/// 计时 Task 由 `seekLandingTimer` 持有，与 observer bag 在同几处取消（`releaseItemObservation`）。
@MainActor
final class AVPlayerTimelineAdapter {
    /// 已发出、尚未收尾的 seek：目标位置，以及是否已观察到落在目标附近的系统 time-jump。
    ///
    /// 收尾时把是否已观察到一并记进落点；未观察到就被新 seek 取代时，目标转入过期落点，
    /// 迟到的跳变据此被吞掉。
    private struct PendingSeek {
        let operationID: UUID
        let targetSeconds: Double
        var observedLanding = false
    }

    /// 一次 seek 的落点，用来辨认迟到或重复的系统 time-jump。
    ///
    /// `observedJump` 表示已经见过落在这里的系统跳变：之后再落在这里的跳变（例如暂停中 seek 后开播时
    /// 系统再报一次）仍按同一次 seek 吞掉；被新 seek 或外部跳变取代时，已见过的落点不再转入过期落点，
    /// 否则之后真正回到这个位置的跳变会被误吞。
    private struct SeekLanding {
        let operationID: UUID
        let positionSeconds: Double
        var observedJump = false
    }

    /// 按住期间的临时倍速；只有同一 ID、同一 item 时 `endMomentaryRate` 才恢复速率。
    private struct MomentaryRateSession {
        let id: UUID
        let item: AVPlayerItem
        let rate: Float
    }

    var onFailed: (@MainActor () -> Void)?
    var onSeekSupersededByExternalJump: (@MainActor (UUID) -> Void)?

    var currentSnapshot: PlaybackTimelineSnapshot {
        store.currentSnapshot
    }

    var hasObservedPlaybackInteraction: Bool {
        interactionTracker.hasObservedInteraction
    }

    var playbackInteractionRevision: UInt64 {
        interactionTracker.revision
    }

    /// 记住的过期 seek 落点上限；只用来辨认迟到的系统 time-jump，最早的先丢。
    private static let maximumStaleSeekLandings = 16

    private let player: AVPlayer
    private let store = PlaybackTimelineStore()
    private let observers = PlayerTimelineObserverBag()
    /// 当前 item 的时间线 token，由 `begin` 向 store 领取，`clear` 时置 nil。
    ///
    /// 每个 observer 捕获安装时的 token，store 丢弃与当前不符的写入，旧 item 的回调不会推进时间线。
    private var token: PlaybackTimelineItemToken?
    /// 已报告失败的 token：status 与 failedToPlayToEnd 两路失败对同一 item 只报告一次。
    private var failedToken: PlaybackTimelineItemToken?
    private var momentaryRateSession: MomentaryRateSession?
    private var pendingSeek: PendingSeek?
    /// 最近一次已收尾的 seek 落点；之后落在附近的系统跳变都按这次 seek 吞掉，直到播放离开落点
    /// （`observePeriodicPosition`），或被新 seek、外部跳变、换 item、clear 取代。
    private var completedSeekLanding: SeekLanding?
    private var staleSeekLandings: [SeekLanding] = []
    private var interactionTracker = PlaybackInteractionTracker()
    private var startPositionSeconds: Double = 0
    private let seekLandingTimer: PlaybackSeekLandingTimer
    /// 进入 seeking 时跳变所在的 timebase，落地时从它读取落点；落地、换 item、失败与 clear 时置 nil。
    private var seekingTimebase: CMTimebase?

    /// `landingClock` 是 seek 落地计时的时钟边界，生产用 `ContinuousClock`。
    init(
        player: AVPlayer,
        landingClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.player = player
        seekLandingTimer = PlaybackSeekLandingTimer(clock: landingClock)
        let initialRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = initialRate
    }

    func updates() -> AsyncStream<PlaybackTimelineSnapshot> {
        store.updates()
    }

    func observe(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        store.observe(observer)
    }

    /// `startPositionSeconds` 是 playlist 的起播位置（从头为 0），就绪时据此标记时间轴不连续。
    func begin(
        identity: PlaybackItemIdentity,
        loadIntent: PlaybackLoadIntent = PlaybackLoadIntent(),
        startPositionSeconds: Double = 0
    ) {
        momentaryRateSession = nil
        releaseItemObservation()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        self.startPositionSeconds = startPositionSeconds
        interactionTracker = PlaybackInteractionTracker(
            startPositionSeconds: startPositionSeconds
        )
        token = store.beginItem(identity: identity, loadIntent: loadIntent)
        failedToken = nil
    }

    /// 为当前 item 安装位置、速率、状态、结束、失败、时间跳变与 timebase 跳变观察，并替换旧观察集合。
    func installObservers(for item: AVPlayerItem) {
        releaseItemObservation()
        guard let token else { return }
        let interactionTracker = interactionTracker

        let periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self, weak item] time in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    self.token == token,
                    let seconds = Self.seconds(from: time)
                else { return }
                self.observePeriodicPosition(seconds)
            }
        }

        let rateObservation = player.observe(\.rate, options: [.initial, .new]) {
            [weak self, weak item] player, _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(token: token, rate: Double(player.rate))
            }
        }

        let timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self, weak item] player, change in
            let observedStatus = change.newValue ?? player.timeControlStatus
            interactionTracker.observeTimeControlStatus(
                isPaused: observedStatus == .paused,
                isPlaying: observedStatus == .playing,
                playbackRate: player.rate
            )
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                let currentState = self.store.currentSnapshot.state
                guard currentState != .failed else { return }
                switch observedStatus {
                case .paused:
                    guard currentState != .ended,
                        currentState != .loading
                            || interactionTracker.hasObservedInteraction
                    else {
                        return
                    }
                    self.store.update(token: token, rate: 0, state: .paused)
                case .waitingToPlayAtSpecifiedRate:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .buffering
                    )
                case .playing:
                    self.store.update(
                        token: token,
                        rate: Double(player.rate),
                        state: .playing
                    )
                @unknown default:
                    return
                }
            }
        }

        let endNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else {
                    return
                }
                self.store.update(
                    token: token,
                    positionSeconds: Self.seconds(from: item.currentTime()),
                    rate: 0,
                    state: .ended
                )
                self.momentaryRateSession = nil
            }
        }

        let statusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] observedItem, _ in
            Task { @MainActor in
                guard observedItem.status == .failed,
                    let self,
                    let item
                else { return }
                self.fail(item: item, token: token)
            }
        }

        let failureNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item else { return }
                self.fail(item: item, token: token)
            }
        }

        let timeJumpNotificationObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.player.currentItem === item,
                    let position = Self.seconds(from: item.currentTime())
                else { return }
                self.observeTimeJump(at: position)
            }
        }

        // AVPlayerItem 创建时就带只读 timebase，换 player 也不变；万一没有，就没有 seek 阶段与落地，
        // 弹幕只在换项时补位。
        let timebaseJumpObserver = item.timebase.map { timebase in
            PlaybackTimebaseJumps.observe(timebase) { [weak self, weak item] jump in
                Task { @MainActor in
                    guard let self, let item, self.player.currentItem === item,
                        self.token == token
                    else { return }
                    self.observeTimebaseJump(jump, on: timebase)
                }
            }
        }

        observers.replace(
            player: player,
            periodicTimeObserver: periodicTimeObserver,
            rateObservation: rateObservation,
            timeControlObservation: timeControlObservation,
            statusObservation: statusObservation,
            endNotificationObserver: endNotificationObserver,
            failureNotificationObserver: failureNotificationObserver,
            timeJumpNotificationObserver: timeJumpNotificationObserver,
            timebaseJumpObserver: timebaseJumpObserver
        )
    }

    /// timebase 跳变的主线程入口：seek 跳变进入 seeking，位置写为跳变时的 timebase 时间，并重新计时
    /// 落地。
    ///
    /// 由 `installObservers` 安装的通知回调切回主线程后调用，`jump` 是通知线程上当场读到的值。音频
    /// 时钟重新锚定的跳变（速率大于 0，见 `PlaybackTimebaseJump`）不进入 seeking，也不刷新落地计时，
    /// 否则每次继续播放、改速率都会让弹幕清屏重补。加载中的跳变（续播起点就位）不算 seek，起点由
    /// `markReady` 落地。
    func observeTimebaseJump(_ jump: PlaybackTimebaseJump, on timebase: CMTimebase) {
        guard jump.isSeek, let token, store.currentSnapshot.state != .loading else { return }
        seekingTimebase = timebase
        store.beginSeeking(token: token, positionSeconds: jump.positionSeconds)
        seekLandingTimer.restart { [weak self] in
            self?.landSeek()
        }
    }

    private func landSeek() {
        guard let token, let timebase = seekingTimebase else { return }
        seekingTimebase = nil
        store.land(
            token: token,
            positionSeconds: Self.seconds(from: CMTimebaseGetTime(timebase))
                ?? store.currentSnapshot.positionSeconds
        )
    }

    /// 周期回调的主线程入口：写入位置与速率，并在播放离开上次 seek 落点后结束那个落点的有效期。
    ///
    /// seeking 期间不写位置：读数可能是跳变前的旧位置，位置只随跳变与落地更新。已见过系统跳变的落点
    /// 只在播放位置仍在落点附近时吞掉重复跳变（暂停中 seek 后开播那一次）；位置离开超过容差后，之后
    /// 回到原处的原生 seek 是新的不连续，不能再被吞掉。还没见过跳变的落点保留，等迟到的跳变。
    func observePeriodicPosition(_ seconds: Double) {
        guard let token else { return }
        if let completedSeekLanding, completedSeekLanding.observedJump,
            abs(seconds - completedSeekLanding.positionSeconds)
                > SeekPolicy.landingMatchToleranceSeconds
        {
            self.completedSeekLanding = nil
        }
        let isSeeking = store.currentSnapshot.seekPhase == .seeking
        store.update(
            token: token,
            positionSeconds: isSeeking ? nil : seconds,
            rate: Double(player.rate)
        )
    }

    /// 释放当前 item 的全部观察并取消落地计时；换 item、安装新观察、失败与 clear 时调用。
    private func releaseItemObservation() {
        observers.reset()
        seekLandingTimer.cancel()
        seekingTimebase = nil
    }

    func markReady(duration: CMTime) {
        guard let token else { return }
        store.markReady(
            token: token,
            durationSeconds: Self.seconds(from: duration)
        )
        // 从 playlist 起播位置开始的 item 一就绪就位于该处；标记不连续并算一次落地，弹幕等消费方从
        // 这里排起，而不是把 0 到起播位置之间当作连续前进。
        guard startPositionSeconds > 0 else { return }
        store.markDiscontinuity(
            token: token,
            positionSeconds: Self.seconds(from: player.currentTime())
                ?? startPositionSeconds,
            lands: true
        )
    }

    func markFailed() {
        momentaryRateSession = nil
        releaseItemObservation()
        guard let token else { return }
        failedToken = token
        store.markFailed(token: token)
    }

    func play() {
        guard let token else { return }
        let preferredRate = Self.validatedPlaybackRate(player.defaultRate) ?? 1
        player.defaultRate = preferredRate
        player.playImmediately(atRate: preferredRate)
        store.update(
            token: token,
            rate: Double(preferredRate),
            state: .playing
        )
    }

    func playAfterInternalSeek() {
        interactionTracker.allowInternalPlayStart()
        play()
    }

    func pause() {
        guard let token else { return }
        interactionTracker.markObserved()
        momentaryRateSession = nil
        player.pause()
        store.update(token: token, rate: 0, state: .paused)
    }

    func setRate(_ rate: Double) throws {
        guard PlaybackRate.isSupported(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        momentaryRateSession = nil
        player.defaultRate = Float(rate)
        guard player.rate > 0, let token else { return }
        player.rate = Float(rate)
        store.update(token: token, rate: rate, state: .playing)
    }

    func beginMomentaryRate(_ rate: Double) throws -> UUID? {
        guard PlaybackRate.isSupported(rate) else {
            throw AVPlayerEngineError.invalidPlaybackRate
        }
        guard let token,
            let item = player.currentItem,
            player.rate > 0
        else {
            return nil
        }

        let session = MomentaryRateSession(
            id: UUID(),
            item: item,
            rate: Float(rate)
        )
        momentaryRateSession = session
        player.rate = session.rate
        store.update(token: token, rate: rate, state: .playing)
        return session.id
    }

    func endMomentaryRate(sessionID: UUID) {
        guard let session = momentaryRateSession,
            session.id == sessionID
        else {
            return
        }
        momentaryRateSession = nil

        guard player.currentItem === session.item, let token
        else {
            return
        }
        let restorationAction = MomentaryRateRestorationPolicy.action(
            timeControlStatus: player.timeControlStatus,
            currentRate: player.rate,
            momentaryRate: session.rate
        )
        switch restorationAction {
        case .none:
            return
        case .setCurrentRate:
            player.rate = player.defaultRate
        case .resumeAtDefaultRate:
            player.play()
        }
        let restoredState: PlaybackTimelineState =
            player.timeControlStatus == .playing ? .playing : .buffering
        store.update(
            token: token,
            rate: Double(player.defaultRate),
            state: restoredState
        )
    }

    func prepareResumeRestart(operationID: UUID) {
        interactionTracker.markObservedAllowingInternalSeek(to: 0)
        beginPendingSeek(operationID: operationID, to: 0)
    }

    /// 用户或 transport 发起的 seek：先记为用户交互，再登记待定落点。
    func prepareObservedSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        interactionTracker.markObservedAllowingInternalSeek(to: positionSeconds)
        beginPendingSeek(operationID: operationID, to: positionSeconds)
    }

    private func beginPendingSeek(
        operationID: UUID,
        to positionSeconds: Double
    ) {
        if let pendingSeek, !pendingSeek.observedLanding {
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
        }
        if let completedSeekLanding, !completedSeekLanding.observedJump {
            appendStaleSeekLanding(completedSeekLanding)
        }
        pendingSeek = PendingSeek(
            operationID: operationID,
            targetSeconds: positionSeconds
        )
        completedSeekLanding = nil
    }

    func observeTimeJump(at positionSeconds: Double) {
        interactionTracker.observeTimeJump(at: positionSeconds)
        guard store.currentSnapshot.state != .loading, let token else { return }
        if var pendingSeek {
            let currentDistance = abs(
                pendingSeek.targetSeconds - positionSeconds
            )
            if consumeStaleSeekLanding(
                at: positionSeconds,
                closerThan: currentDistance
            ) {
                return
            }
            if currentDistance <= SeekPolicy.landingMatchToleranceSeconds {
                discardEquivalentStaleSeekLandings(
                    to: pendingSeek.targetSeconds
                )
                pendingSeek.observedLanding = true
                self.pendingSeek = pendingSeek
                return
            }
            appendStaleSeekLanding(
                operationID: pendingSeek.operationID,
                positionSeconds: pendingSeek.targetSeconds
            )
            self.pendingSeek = nil
            completedSeekLanding = nil
            interactionTracker.markObserved()
            store.markDiscontinuity(
                token: token,
                positionSeconds: positionSeconds
            )
            onSeekSupersededByExternalJump?(pendingSeek.operationID)
            return
        }
        let completedDistance =
            completedSeekLanding.map {
                abs($0.positionSeconds - positionSeconds)
            } ?? .infinity
        if consumeStaleSeekLanding(
            at: positionSeconds,
            closerThan: completedDistance
        ) {
            return
        }
        if completedDistance <= SeekPolicy.landingMatchToleranceSeconds,
            var completedSeekLanding
        {
            discardEquivalentStaleSeekLandings(
                to: completedSeekLanding.positionSeconds
            )
            // 落点继续有效：暂停中 seek 后开播时系统会在原处再报一次跳变，它不是新的不连续。
            completedSeekLanding.observedJump = true
            self.completedSeekLanding = completedSeekLanding
            return
        }
        if let completedSeekLanding, !completedSeekLanding.observedJump {
            appendStaleSeekLanding(completedSeekLanding)
        }
        completedSeekLanding = nil
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func seekFailed(operationID: UUID) {
        guard pendingSeek?.operationID == operationID else { return }
        pendingSeek = nil
        interactionTracker.cancelInternalSeek()
    }

    func discardStaleSeekLanding(operationID: UUID) {
        staleSeekLandings.removeAll {
            $0.operationID == operationID
        }
    }

    private func discardEquivalentStaleSeekLandings(to positionSeconds: Double) {
        staleSeekLandings.removeAll {
            abs($0.positionSeconds - positionSeconds) <= 0.000_001
        }
    }

    func seekCompleted(
        operationID: UUID,
        at positionSeconds: Double
    ) {
        guard let completedPendingSeek = pendingSeek,
            completedPendingSeek.operationID == operationID,
            let token
        else { return }
        pendingSeek = nil
        completedSeekLanding = SeekLanding(
            operationID: operationID,
            positionSeconds: positionSeconds,
            observedJump: completedPendingSeek.observedLanding
        )
        interactionTracker.completeInternalSeek(at: positionSeconds)
        store.markDiscontinuity(
            token: token,
            positionSeconds: positionSeconds
        )
    }

    func clear() {
        momentaryRateSession = nil
        releaseItemObservation()
        pendingSeek = nil
        completedSeekLanding = nil
        staleSeekLandings.removeAll(keepingCapacity: true)
        store.clear(token: token)
        token = nil
        failedToken = nil
    }

    private func appendStaleSeekLanding(
        operationID: UUID,
        positionSeconds: Double
    ) {
        appendStaleSeekLanding(
            SeekLanding(
                operationID: operationID,
                positionSeconds: positionSeconds
            )
        )
    }

    private func appendStaleSeekLanding(_ landing: SeekLanding) {
        staleSeekLandings.append(landing)
        if staleSeekLandings.count > Self.maximumStaleSeekLandings {
            staleSeekLandings.removeFirst()
        }
    }

    private func consumeStaleSeekLanding(
        at positionSeconds: Double,
        closerThan competingDistance: Double
    ) -> Bool {
        guard
            let candidate = staleSeekLandings.enumerated().min(
                by: {
                    abs($0.element.positionSeconds - positionSeconds)
                        < abs($1.element.positionSeconds - positionSeconds)
                }
            )
        else { return false }
        let distance = abs(candidate.element.positionSeconds - positionSeconds)
        guard distance <= SeekPolicy.landingMatchToleranceSeconds,
            distance < competingDistance
        else { return false }
        staleSeekLandings.remove(at: candidate.offset)
        return true
    }

    private func fail(
        item: AVPlayerItem,
        token: PlaybackTimelineItemToken
    ) {
        guard player.currentItem === item,
            self.token == token,
            failedToken != token,
            store.currentSnapshot.state != .loading
        else { return }

        failedToken = token
        momentaryRateSession = nil
        releaseItemObservation()
        store.markFailed(token: token)
        onFailed?()
    }

    private nonisolated static func seconds(from time: CMTime) -> Double? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func validatedPlaybackRate(_ rate: Float) -> Float? {
        guard PlaybackRate.isSupported(rate) else { return nil }
        return rate
    }
}

/// 当前 item 的 AVPlayer 观察集合（periodic observer、KVO、item 通知与 timebase 跳变通知 observer）。
///
/// 替换或清空时在锁内整体换出，在锁外注销换出的旧集合；deinit 兜底注销。timebase 通知在 CoreMedia
/// 后台线程上回调，注销之后不再回调；注销前已切回主线程的回调由 adapter 比对 item 与 token 丢弃。
///
/// 用 `OSAllocatedUnfairLock(uncheckedState:)` 而不用 `Mutex`：`replace` 要把调用方传入的 observer
/// （`Any`、`NSObjectProtocol` 等非 Sendable 值）存进锁内状态，`Mutex` 的 `inout sending` 闭包参数
/// 不允许并入这类外部值。
private final class PlayerTimelineObserverBag: Sendable {
    /// 当前观察集合；`player` 用于注销 periodic observer，其余各项各自 invalidate 或从
    /// NotificationCenter 移除。
    private struct Storage {
        var player: AVPlayer? = nil
        var periodicTimeObserver: Any? = nil
        var rateObservation: NSKeyValueObservation? = nil
        var timeControlObservation: NSKeyValueObservation? = nil
        var statusObservation: NSKeyValueObservation? = nil
        var endNotificationObserver: NSObjectProtocol? = nil
        var failureNotificationObserver: NSObjectProtocol? = nil
        var timeJumpNotificationObserver: NSObjectProtocol? = nil
        var timebaseJumpObserver: NSObjectProtocol? = nil
    }

    private let storage = OSAllocatedUnfairLock(uncheckedState: Storage())

    deinit {
        reset()
    }

    func replace(
        player: AVPlayer,
        periodicTimeObserver: Any,
        rateObservation: NSKeyValueObservation,
        timeControlObservation: NSKeyValueObservation,
        statusObservation: NSKeyValueObservation,
        endNotificationObserver: NSObjectProtocol,
        failureNotificationObserver: NSObjectProtocol,
        timeJumpNotificationObserver: NSObjectProtocol,
        timebaseJumpObserver: NSObjectProtocol?
    ) {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage(
                player: player,
                periodicTimeObserver: periodicTimeObserver,
                rateObservation: rateObservation,
                timeControlObservation: timeControlObservation,
                statusObservation: statusObservation,
                endNotificationObserver: endNotificationObserver,
                failureNotificationObserver: failureNotificationObserver,
                timeJumpNotificationObserver: timeJumpNotificationObserver,
                timebaseJumpObserver: timebaseJumpObserver
            )
            return previous
        }
        Self.remove(previous)
    }

    func reset() {
        let previous = storage.withLockUnchecked { storage -> Storage in
            let previous = storage
            storage = Storage()
            return previous
        }
        Self.remove(previous)
    }

    private static func remove(_ storage: Storage) {
        if let player = storage.player,
            let periodicTimeObserver = storage.periodicTimeObserver
        {
            player.removeTimeObserver(periodicTimeObserver)
        }
        storage.rateObservation?.invalidate()
        storage.timeControlObservation?.invalidate()
        storage.statusObservation?.invalidate()
        let notificationObservers = [
            storage.endNotificationObserver,
            storage.failureNotificationObserver,
            storage.timeJumpNotificationObserver,
            storage.timebaseJumpObserver
        ]
        for observer in notificationObservers.compactMap(\.self) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
