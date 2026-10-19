import AVFoundation
import Foundation

/// item timebase 的 time-jump 通知入口，是时间线识别 seek 的唯一来源。
///
/// timebase 只在时间被直接设定时发 `kCMTimebaseNotification_TimeJumped`：seek（含拖动的每一步）与
/// 播放到结尾时各一次；播放、暂停、改速率与缓冲停顿只改有效速率，不发跳变。通知在 CoreMedia 的后台
/// 线程上同步发出，`handler` 在那个线程上调用，调用方自行切回主线程。返回的 observer 由调用方的
/// observer 集合持有，换 item、失败与 clear 时随集合一起移除。
enum PlaybackTimebaseJumps {
    static func observe(
        _ timebase: CMTimebase,
        handler: @escaping @Sendable () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCMTimebaseNotification_TimeJumped as String),
            object: timebase,
            queue: nil
        ) { _ in
            handler()
        }
    }
}

/// 把一串 time-jump 收敛为一次落地的计时器。
///
/// 由 `AVPlayerTimelineAdapter` 持有，MainActor 隔离。每次跳变调用 `restart`：取消上一次计时并重新
/// 计 `quietInterval`，到点仍是最后一次跳变才调用 `onLanding`。拥有计时 Task，取消点是 `restart`
/// （被新跳变取代）与 `cancel`（换 item、失败、clear）；不拥有时间线写入，落地由回调方完成。
@MainActor
final class PlaybackSeekLandingTimer {
    /// 最后一次跳变之后静默多久算落地。
    ///
    /// 拖动进度条时跳变一个接一个、间隔远小于它，拖动期间因此一直是 seeking，停稳后只落地一次；
    /// 暂停中 seek 时有效速率一直为 0，播放中拖动时每步之间速率又会恢复，都不能以速率恢复判定落地，
    /// 只能看静默时长。代价是单次 seek（键盘、评论时间戳）最多晚这么久补位，而缓冲通常比它更长。
    /// 调大会让停下后更晚出现弹幕，调小则慢速拖动时更容易在中途落地。
    static let quietInterval = Duration.milliseconds(150)

    private let clock: any Clock<Duration>
    private var landingTask: Task<Void, Never>?
    /// `restart` 与 `cancel` 时递增；计时 Task 带上发起时的值，到点不等就不落地，被取代的计时即使
    /// 没来得及响应取消也不会落地。
    private var sequence: UInt64 = 0

    /// `clock` 是计时边界：生产用 `ContinuousClock`。
    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func restart(onLanding: @escaping @MainActor () -> Void) {
        landingTask?.cancel()
        sequence &+= 1
        let expectedSequence = sequence
        landingTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.quietInterval)
            } catch {
                return
            }
            guard let self, self.sequence == expectedSequence else { return }
            self.landingTask = nil
            onLanding()
        }
    }

    func cancel() {
        landingTask?.cancel()
        landingTask = nil
        sequence &+= 1
    }
}
