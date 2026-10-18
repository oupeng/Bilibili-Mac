import BiliApplication
import BiliModels
import BiliVideoDetailFeature
import Foundation

/// 一个窗口在进程级 `SystemNowPlayingController` 里的登记：
/// 把本窗口当前呈现的视频与播放时间线同步成一份会话，由 controller 在多个窗口之间选出发布者。
///
/// 由 `WindowComposition` 构造并持有，构造时向 controller 登记窗口 ID。
/// `start()`（窗口 `open()` 时）开始消费时间线更新、观察 `defaultRate` 与视频模型的呈现；
/// `close()`（窗口 `close()` 时）不可逆，取消时间线 Task 与 KVO 观察并从 controller 移除本窗口，
/// 之后迟到的观察回调因 `isClosed` 不再同步；未关闭就释放时由 `isolated deinit` 做同样的清理。
/// 全部在 MainActor 上运行。
///
/// 呈现的视频、分 P 与时间线 identity 不一致，或播放器没有 item 时，从 controller 移除本窗口，
/// 不发布旧内容。
@MainActor
final class SystemNowPlayingWindowCoordinator {
    private let controller: SystemNowPlayingController
    private let connection: SystemNowPlayingPlaybackConnection
    private let videoModel: VideoViewModel
    private let windowID: UUID
    private var observationTask: Task<Void, Never>?
    private var defaultRateObservation: SystemNowPlayingDefaultRateObservation?
    /// 本窗口的 Now Playing 来源（播放 identity 加 `AVPlayerItem`）每变化一次以 `&+=` 递增，
    /// 同一来源的时间线更新不递增。
    ///
    /// controller 把它放进发布身份：来源变化时重新发布并重新加载封面，
    /// 旧来源的封面迟到时因身份不同被丢弃；选择发布窗口时它是选择次序之后的次级排序。
    private var generation: UInt64 = 0
    private var sourceIdentity: SystemNowPlayingSourceIdentity?
    private var isClosed = false

    init(
        controller: SystemNowPlayingController,
        connection: SystemNowPlayingPlaybackConnection,
        videoModel: VideoViewModel
    ) {
        self.controller = controller
        self.connection = connection
        self.videoModel = videoModel
        windowID = controller.registerWindow()
    }

    isolated deinit {
        observationTask?.cancel()
        defaultRateObservation?.cancel()
        controller.removeWindow(windowID)
    }

    func start() {
        guard observationTask == nil, !isClosed else { return }
        synchronize(with: connection.currentSnapshot())
        observationTask = Task { [weak self, connection] in
            for await snapshot in connection.timelineUpdates() {
                guard !Task.isCancelled else { return }
                self?.synchronize(with: snapshot)
            }
        }
        defaultRateObservation = connection.observeDefaultPlaybackRate {
            [weak self] _ in
            guard let self, !self.isClosed else { return }
            self.synchronize(with: self.connection.currentSnapshot())
        }
        observePresentation()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        observationTask?.cancel()
        observationTask = nil
        defaultRateObservation?.cancel()
        defaultRateObservation = nil
        controller.removeWindow(windowID)
    }

    func markWindowActive() {
        controller.markWindowActive(windowID)
    }

    private func observePresentation() {
        guard !isClosed else { return }
        withObservationTracking {
            _ = videoModel.presentedContext
            _ = videoModel.presentedPlaybackIdentity
            _ = videoModel.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                self.synchronize(with: self.connection.currentSnapshot())
                self.observePresentation()
            }
        }
    }

    private func synchronize(with timeline: PlaybackTimelineSnapshot) {
        guard let context = videoModel.presentedContext,
            let identity = videoModel.presentedPlaybackIdentity,
            timeline.identity == identity,
            context.detail.bvid == identity.bvid,
            context.selectedPage.cid == identity.cid,
            let itemIdentifier = connection.currentItemIdentifier()
        else {
            controller.removeWindow(windowID)
            sourceIdentity = nil
            return
        }
        let nextSourceIdentity = SystemNowPlayingSourceIdentity(
            playbackIdentity: identity,
            playerItemIdentifier: itemIdentifier
        )
        if nextSourceIdentity != sourceIdentity {
            generation &+= 1
            sourceIdentity = nextSourceIdentity
        }
        controller.update(
            windowID: windowID,
            generation: generation,
            playbackIdentity: identity,
            playerItemIdentifier: itemIdentifier,
            presentation: SystemNowPlayingPresentation(
                totalTitle: context.detail.title,
                artist: context.detail.owner.name,
                partTitle: context.selectedPage.title,
                partCount: context.pages.count,
                coverURL: context.detail.coverURL
            ),
            timeline: timeline,
            defaultPlaybackRate: connection.currentDefaultPlaybackRate(),
            perform: connection.perform
        )
    }
}

private struct SystemNowPlayingSourceIdentity: Equatable {
    let playbackIdentity: PlaybackItemIdentity
    let playerItemIdentifier: ObjectIdentifier
}
