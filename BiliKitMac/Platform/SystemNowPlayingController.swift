@preconcurrency import AppKit
import BiliApplication
import Foundation
@preconcurrency import MediaPlayer

/// 交给系统 Now Playing 的标题信息：标题、UP 主、专辑与封面地址。
///
/// 多分 P 且分 P 标题非空、与总标题不同时，标题取分 P 标题、专辑取总标题；否则标题取总标题、
/// 不设专辑。空白 UP 主名不显示。封面只经本 controller 的进程级图片管线加载，请求与响应校验见
/// SECURITY-MODEL §4。
struct SystemNowPlayingPresentation: Equatable, Sendable {
    let title: String
    let artist: String?
    let albumTitle: String?
    let coverURL: URL?

    init(
        totalTitle: String,
        artist: String,
        partTitle: String?,
        partCount: Int,
        coverURL: URL?
    ) {
        let normalizedTotal = totalTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedPart = partTitle?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let normalizedPart,
            partCount > 1,
            !normalizedPart.isEmpty,
            normalizedPart != normalizedTotal
        {
            title = normalizedPart
            albumTitle = normalizedTotal
        } else {
            title = normalizedTotal
            albumTitle = nil
        }
        let normalizedArtist = artist.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.artist = normalizedArtist.isEmpty ? nil : normalizedArtist
        self.coverURL = coverURL
    }
}

/// 系统远程命令（媒体键、控制中心等）转成的播放命令。
///
/// `skip(interval:direction:)` 拒绝非有限或非正的间隔；位置与偏移再由 `SystemNowPlayingController`
/// 按胜出会话的时间轴校验，窗口执行前还会核对 identity 与 player item。
enum SystemNowPlayingCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case seek(positionSeconds: Double)
    case skip(offsetSeconds: Double)

    static func skip(
        interval: Double,
        direction: SystemNowPlayingSkipDirection
    ) -> SystemNowPlayingCommand? {
        guard interval.isFinite, interval > 0 else { return nil }
        return .skip(
            offsetSeconds: direction == .forward ? interval : -interval
        )
    }
}

/// 系统快进或快退命令的方向。
enum SystemNowPlayingSkipDirection: Sendable {
    case forward
    case backward
}

/// 远程命令的处理结果，一一映射到 `MPRemoteCommandHandlerStatus`。
enum SystemNowPlayingCommandResult: Equatable, Sendable {
    case success
    case noSuchContent
    case commandFailed
}

/// 一个窗口最近一次上报的播放会话，只在 MainActor 上读写。
///
/// `generation` 由 `SystemNowPlayingWindowCoordinator` 在播放 identity 或 player item 变化时递增；
/// `selectionOrder` 取 controller 的 `selectionClock`。多个窗口竞争时先取正在播放（含缓冲）的会话，
/// 再按（`selectionOrder`, `generation`）取最大者。`perform` 把命令连同会话的 identity 与 item
/// 交回窗口，窗口发现已不是同一项时拒绝。
@MainActor
private struct SystemNowPlayingSession {
    let windowID: UUID
    let generation: UInt64
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
    let presentation: SystemNowPlayingPresentation
    let timeline: PlaybackTimelineSnapshot
    let defaultPlaybackRate: Double
    let perform:
        (
            SystemNowPlayingCommand,
            PlaybackItemIdentity,
            ObjectIdentifier
        ) -> Bool
    var selectionOrder: UInt64

    var isPlaying: Bool {
        timeline.state == .playing || timeline.state == .buffering
    }

    var isValid: Bool {
        timeline.identity == playbackIdentity
            && timeline.durationSeconds.map { $0 > 0 } == true
            && timeline.state != .idle
            && timeline.state != .loading
            && timeline.state != .failed
    }
}

/// 已发布到系统的会话身份；变化时重新发布并重新加载封面，迟到的封面按它比对后丢弃。
private struct SystemNowPlayingPublicationIdentity: Equatable {
    let windowID: UUID
    let generation: UInt64
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
}

/// 决定是否重新发布的时间轴摘要。
///
/// 不含播放位置：正常播放时由系统按速率推算已播时长，只有跳转（`discontinuityGeneration`）、时长、
/// 速率或状态变化才需要重新发布。
private struct SystemNowPlayingTimelineFingerprint: Equatable {
    let identity: PlaybackItemIdentity?
    let durationSeconds: Double?
    let rate: Double
    let defaultPlaybackRate: Double
    let state: PlaybackTimelineState
    let discontinuityGeneration: UInt64
}

/// 系统 Now Playing 信息中心的写入 port：`publish` 整体替换信息与播放状态，`clear` 清空信息并置为
/// stopped。
@MainActor
protocol SystemNowPlayingCenterWriting: AnyObject {
    func publish(info: [String: Any], state: MPNowPlayingPlaybackState)
    func clear()
}

/// 写入 `MPNowPlayingInfoCenter.default()` 的实现。
@MainActor
private final class DefaultSystemNowPlayingCenter: SystemNowPlayingCenterWriting {
    private let center: MPNowPlayingInfoCenter

    init(center: MPNowPlayingInfoCenter = .default()) {
        self.center = center
    }

    func publish(info: [String: Any], state: MPNowPlayingPlaybackState) {
        center.nowPlayingInfo = info
        center.playbackState = state
    }

    func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

/// 系统远程命令的注册 port：`install` 注册一次处理闭包（已注册时忽略），`removeHandlers`
/// 移除全部注册。
///
/// 处理闭包的调用线程不固定，且必须同步返回结果。
@MainActor
protocol SystemRemoteCommandManaging: AnyObject {
    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    )
    func removeHandlers()
}

/// 注册到 `MPRemoteCommandCenter.shared()` 的远程命令：播放、暂停、切换、拖动进度与前后 15 秒跳转。
///
/// 同时禁用上一首与下一首。拥有各命令的 target token，`removeHandlers()` 逐个移除；由
/// `SystemNowPlayingController` 在 deinit 时调用。MainActor 隔离。
@MainActor
private final class DefaultSystemRemoteCommandManager:
    SystemRemoteCommandManaging
{
    private let center: MPRemoteCommandCenter
    private var registrations: [(command: MPRemoteCommand, token: Any)] = []

    init(center: MPRemoteCommandCenter = .shared()) {
        self.center = center
    }

    func install(
        handler:
            @escaping @Sendable (SystemNowPlayingCommand) ->
            SystemNowPlayingCommandResult
    ) {
        guard registrations.isEmpty else { return }

        register(center.playCommand) { _ in handler(.play) }
        register(center.pauseCommand) { _ in handler(.pause) }
        register(center.togglePlayPauseCommand) { _ in
            handler(.togglePlayPause)
        }
        register(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                event.positionTime.isFinite,
                event.positionTime >= 0
            else { return .commandFailed }
            return handler(.seek(positionSeconds: event.positionTime))
        }
        center.skipForwardCommand.preferredIntervals = [15]
        register(center.skipForwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                let command = SystemNowPlayingCommand.skip(
                    interval: event.interval,
                    direction: .forward
                )
            else { return .commandFailed }
            return handler(command)
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        register(center.skipBackwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent,
                let command = SystemNowPlayingCommand.skip(
                    interval: event.interval,
                    direction: .backward
                )
            else { return .commandFailed }
            return handler(command)
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    func removeHandlers() {
        guard !registrations.isEmpty else { return }
        for registration in registrations {
            registration.command.removeTarget(registration.token)
        }
        registrations.removeAll()
    }

    private func register(
        _ command: MPRemoteCommand,
        handler:
            @escaping (MPRemoteCommandEvent) ->
            SystemNowPlayingCommandResult
    ) {
        command.isEnabled = true
        let token = command.addTarget { event in
            switch handler(event) {
            case .success:
                return .success
            case .noSuchContent:
                return .noSuchContent
            case .commandFailed:
                return .commandFailed
            }
        }
        registrations.append((command, token))
    }
}

/// 进程级的系统 Now Playing 与远程命令 owner：从所有窗口上报的播放会话里选出一个发布给系统。
///
/// 由 `ProcessComposition` 创建并持有到进程结束；每个窗口经 `SystemNowPlayingWindowCoordinator`
/// 调用 `registerWindow`、`update`、`markWindowActive` 与 `removeWindow`。拥有窗口会话表、
/// 远程命令注册、已发布的封面与封面加载 Task，以及只用于封面的进程级图片管线（缓存上限
/// `nowPlayingArtwork`）；不拥有播放器，远程命令经胜出会话的 `perform` 交回窗口执行。
/// 生产里随进程存活、不提前关闭；isolated deinit 取消封面加载、关闭封面管线、移除远程命令并清空
/// 系统信息。`center`、`remoteCommands` 与 `artworkLoader` 是系统 Now Playing、远程命令与封面网络的
/// 边界，生产传 nil，由本类型构造系统实现与进程级封面管线。MainActor 隔离，远程命令回调经 `handleFromAnyThread` 回到主线程。
@MainActor
final class SystemNowPlayingController {
    private let center: any SystemNowPlayingCenterWriting
    private let remoteCommands: any SystemRemoteCommandManaging
    private let artworkLoader: @Sendable (URL) async -> CGImage?
    /// 进程级封面管线：随 controller 存活，只在 deinit 关闭，换曲目只取消等待者。
    private let artworkPipelineOwner: NativeVideoImagePipelineOwner?
    private var sessions: [UUID: SystemNowPlayingSession] = [:]
    /// 窗口选择时钟：会话开始播放、窗口变为活跃、远程命令成功时递增，并赋给该会话的
    /// `selectionOrder`。
    private var selectionClock: UInt64 = 0
    /// 当前发布给系统的会话身份；变化时取消旧封面加载并清空封面，封面到达时与它比对，不等即丢弃。
    private var publishedIdentity: SystemNowPlayingPublicationIdentity?
    private var publishedFingerprint: SystemNowPlayingTimelineFingerprint?
    private var publishedArtwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?

    init(
        center: (any SystemNowPlayingCenterWriting)? = nil,
        remoteCommands: (any SystemRemoteCommandManaging)? = nil,
        artworkLoader: (@Sendable (URL) async -> CGImage?)? = nil
    ) {
        self.center = center ?? DefaultSystemNowPlayingCenter()
        self.remoteCommands =
            remoteCommands ?? DefaultSystemRemoteCommandManager()
        if let artworkLoader {
            self.artworkLoader = artworkLoader
            artworkPipelineOwner = nil
        } else {
            let owner = NativeVideoImagePipelineOwner(cacheLimits: .nowPlayingArtwork)
            self.artworkLoader = { [pipeline = owner.pipeline] url in
                await pipeline.image(for: url, variant: .cover)?.image
            }
            artworkPipelineOwner = owner
        }
        self.remoteCommands.install { [weak self] command in
            guard let self else { return .noSuchContent }
            return self.handleFromAnyThread(command)
        }
    }

    isolated deinit {
        artworkTask?.cancel()
        artworkPipelineOwner?.shutdown()
        remoteCommands.removeHandlers()
        if publishedIdentity != nil {
            center.clear()
        }
    }

    func registerWindow() -> UUID {
        UUID()
    }

    /// 窗口上报当前播放会话，然后重新选择胜出会话并按需发布。
    ///
    /// 会话无效（时间轴 identity 不符、没有正时长、空闲、加载中或失败）时移除该窗口的会话。
    func update(
        windowID: UUID,
        generation: UInt64,
        playbackIdentity: PlaybackItemIdentity,
        playerItemIdentifier: ObjectIdentifier,
        presentation: SystemNowPlayingPresentation,
        timeline: PlaybackTimelineSnapshot,
        defaultPlaybackRate: Double,
        perform:
            @escaping (
                SystemNowPlayingCommand,
                PlaybackItemIdentity,
                ObjectIdentifier
            ) -> Bool
    ) {
        let previous = sessions[windowID]
        var selectionOrder = previous?.selectionOrder ?? 0
        let beganPlaying =
            (timeline.state == .playing || timeline.state == .buffering)
            && previous?.isPlaying != true
        if beganPlaying {
            selectionClock &+= 1
            selectionOrder = selectionClock
        }
        let session = SystemNowPlayingSession(
            windowID: windowID,
            generation: generation,
            playbackIdentity: playbackIdentity,
            playerItemIdentifier: playerItemIdentifier,
            presentation: presentation,
            timeline: timeline,
            defaultPlaybackRate: Self.normalizedDefaultPlaybackRate(
                defaultPlaybackRate
            ),
            perform: perform,
            selectionOrder: selectionOrder
        )
        if session.isValid {
            sessions[windowID] = session
        } else {
            sessions[windowID] = nil
        }
        reconcile()
    }

    func markWindowActive(_ windowID: UUID) {
        guard var session = sessions[windowID], session.isValid else { return }
        selectionClock &+= 1
        session.selectionOrder = selectionClock
        sessions[windowID] = session
        reconcile()
    }

    func removeWindow(_ windowID: UUID) {
        sessions[windowID] = nil
        reconcile()
    }

    /// `MPRemoteCommand` 的处理闭包要同步返回结果且调用线程不固定：在主线程时直接执行，
    /// 否则同步切到主线程等待。
    nonisolated private func handleFromAnyThread(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { handle(command) }
        }
        return DispatchQueue.main.sync { handle(command) }
    }

    /// 把远程命令交给胜出会话执行，成功后该会话成为最近选择。
    ///
    /// 没有会话、已关闭或命令不适用于当前时间轴时为 `.noSuchContent`；窗口拒绝（identity 或 item
    /// 已变）时为 `.commandFailed`。
    func handle(
        _ command: SystemNowPlayingCommand
    ) -> SystemNowPlayingCommandResult {
        guard var winner = winningSession() else {
            return .noSuchContent
        }
        guard commandIsValid(command, for: winner.timeline) else {
            return .noSuchContent
        }
        guard
            winner.perform(
                command,
                winner.playbackIdentity,
                winner.playerItemIdentifier
            )
        else {
            return .commandFailed
        }
        selectionClock &+= 1
        winner.selectionOrder = selectionClock
        sessions[winner.windowID] = winner
        return .success
    }

    private func commandIsValid(
        _ command: SystemNowPlayingCommand,
        for timeline: PlaybackTimelineSnapshot
    ) -> Bool {
        guard timeline.identity != nil, timeline.state != .ended else {
            return false
        }
        switch command {
        case .play, .pause, .togglePlayPause:
            return true
        case .seek(let positionSeconds):
            guard let duration = timeline.durationSeconds else { return false }
            return positionSeconds.isFinite
                && positionSeconds >= 0
                && positionSeconds <= duration
        case .skip(let offsetSeconds):
            return offsetSeconds.isFinite
                && offsetSeconds != 0
                && timeline.durationSeconds.map { $0 > 0 } == true
        }
    }

    private func winningSession() -> SystemNowPlayingSession? {
        let valid = sessions.values.filter(\.isValid)
        let playing = valid.filter(\.isPlaying)
        let candidates = playing.isEmpty ? valid : playing
        return candidates.max { lhs, rhs in
            let lhsRank = (lhs.selectionOrder, lhs.generation)
            let rhsRank = (rhs.selectionOrder, rhs.generation)
            return lhsRank < rhsRank
        }
    }

    private func reconcile() {
        guard let winner = winningSession() else {
            clearPublishedSession()
            return
        }
        let identity = SystemNowPlayingPublicationIdentity(
            windowID: winner.windowID,
            generation: winner.generation,
            playbackIdentity: winner.playbackIdentity,
            playerItemIdentifier: winner.playerItemIdentifier
        )
        let fingerprint = SystemNowPlayingTimelineFingerprint(
            identity: winner.timeline.identity,
            durationSeconds: winner.timeline.durationSeconds,
            rate: Self.effectiveRate(for: winner.timeline),
            defaultPlaybackRate: winner.defaultPlaybackRate,
            state: winner.timeline.state,
            discontinuityGeneration:
                winner.timeline.discontinuityGeneration
        )
        let identityChanged = identity != publishedIdentity
        guard identityChanged || fingerprint != publishedFingerprint else {
            return
        }
        if identityChanged {
            cancelArtworkLoad()
            publishedArtwork = nil
            publishedIdentity = identity
        }
        publishedFingerprint = fingerprint
        publish(winner)
        if identityChanged, let coverURL = winner.presentation.coverURL {
            loadArtwork(from: coverURL, for: identity)
        }
    }

    private func publish(_ session: SystemNowPlayingSession) {
        var info = Self.info(
            presentation: session.presentation,
            timeline: session.timeline,
            defaultPlaybackRate: session.defaultPlaybackRate
        )
        if let publishedArtwork {
            info[MPMediaItemPropertyArtwork] = publishedArtwork
        }
        center.publish(info: info, state: playbackState(for: session.timeline))
    }

    /// 构造 Now Playing 信息字典：媒体类型为视频、非直播、不进入系统推荐，速率只在播放中时非零。
    static func info(
        presentation: SystemNowPlayingPresentation,
        timeline: PlaybackTimelineSnapshot,
        defaultPlaybackRate: Double
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: presentation.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime:
                timeline.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: effectiveRate(for: timeline),
            MPNowPlayingInfoPropertyDefaultPlaybackRate:
                normalizedDefaultPlaybackRate(defaultPlaybackRate),
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExcludeFromSuggestions: true
        ]
        if let artist = presentation.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let albumTitle = presentation.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if let duration = timeline.durationSeconds, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        return info
    }

    nonisolated private static func effectiveRate(
        for timeline: PlaybackTimelineSnapshot
    ) -> Double {
        switch timeline.state {
        case .playing:
            return timeline.rate
        case .idle, .loading, .ready, .paused, .buffering, .ended, .failed:
            return 0
        }
    }

    nonisolated private static func normalizedDefaultPlaybackRate(
        _ rate: Double
    ) -> Double {
        rate.isFinite && rate > 0 ? rate : 1
    }

    private func playbackState(
        for timeline: PlaybackTimelineSnapshot
    ) -> MPNowPlayingPlaybackState {
        switch timeline.state {
        case .playing, .buffering:
            return .playing
        case .ready, .paused, .ended:
            return .paused
        case .idle, .loading, .failed:
            return .stopped
        }
    }

    private func loadArtwork(
        from url: URL,
        for identity: SystemNowPlayingPublicationIdentity
    ) {
        artworkTask = Task { [weak self, artworkLoader] in
            guard let image = await artworkLoader(url),
                !Task.isCancelled
            else { return }
            self?.acceptArtwork(image, for: identity)
        }
    }

    private func acceptArtwork(
        _ image: CGImage,
        for identity: SystemNowPlayingPublicationIdentity
    ) {
        guard publishedIdentity == identity else { return }
        publishedArtwork = Self.makeArtwork(from: image)
        guard let winner = winningSession(),
            publishedIdentity
                == SystemNowPlayingPublicationIdentity(
                    windowID: winner.windowID,
                    generation: winner.generation,
                    playbackIdentity: winner.playbackIdentity,
                    playerItemIdentifier: winner.playerItemIdentifier
                )
        else { return }
        publish(winner)
    }

    nonisolated private static func makeArtwork(
        from image: CGImage
    ) -> MPMediaItemArtwork {
        let size = NSSize(width: image.width, height: image.height)
        return MPMediaItemArtwork(boundsSize: size) { _ in
            NSImage(cgImage: image, size: size)
        }
    }

    private func cancelArtworkLoad() {
        artworkTask?.cancel()
        artworkTask = nil
    }

    private func clearPublishedSession() {
        guard publishedIdentity != nil else { return }
        cancelArtworkLoad()
        publishedArtwork = nil
        publishedIdentity = nil
        publishedFingerprint = nil
        center.clear()
    }
}
