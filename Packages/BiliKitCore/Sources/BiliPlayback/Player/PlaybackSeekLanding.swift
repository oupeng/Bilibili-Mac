import AVFoundation
import Foundation

/// 一次 timebase time-jump 发出那一刻读到的 timebase 时间与速率。
///
/// 只有速率为 0 的跳变是 seek：seek（含拖动的每一步）与播放到结尾时，系统先把 timebase 速率设为 0
/// 再设定时间；带音轨的媒体在开播、继续播放与改速率时，系统按音频时钟重新锚定，也发跳变（时间往回
/// 几十毫秒），但此刻速率已大于 0。播放中 seek 时两者先后各发一次：先在目标处以速率 0 报 seek，约
/// 20ms 后在目标前几十毫秒处以速率大于 0 报重新锚定。这是在 macOS 27 上用本地 HLS 与 mp4（含音轨）
/// 实测的系统行为；AirPlay、码率切换等场景没有验证。速率必须在通知线程上当场读取，切回主线程时
/// 速率可能已经恢复。
struct PlaybackTimebaseJump: Sendable, Equatable {
    /// 跳变后的 timebase 时间（秒）；读不到有效值时为 nil。
    let positionSeconds: Double?
    /// 跳变发出时 timebase 的速率。
    let rate: Double

    var isSeek: Bool { rate == 0 }
}

/// item timebase 的 time-jump 通知入口，是时间线识别 seek 的唯一来源。
///
/// 播放、暂停、改速率与缓冲停顿本身只改有效速率；跳变里哪些是 seek 见 `PlaybackTimebaseJump`。
/// 通知在 CoreMedia 的后台线程上同步发出，`handler` 在那个线程上带着当场读到的时间与速率调用，
/// 调用方自行切回主线程。返回的 observer 由调用方的 observer 集合持有，换 item、失败与 clear 时随
/// 集合一起移除。
enum PlaybackTimebaseJumps {
    static func observe(
        _ timebase: CMTimebase,
        handler: @escaping @Sendable (PlaybackTimebaseJump) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name(kCMTimebaseNotification_TimeJumped as String),
            object: timebase,
            queue: nil
        ) { _ in
            let seconds = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            handler(
                PlaybackTimebaseJump(
                    positionSeconds: seconds.isFinite && seconds >= 0 ? seconds : nil,
                    rate: CMTimebaseGetRate(timebase)
                )
            )
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
    /// 拖动进度条时 seek 跳变一个接一个、间隔远小于它，拖动期间因此一直是 seeking，停稳后只落地一次；
    /// 暂停中 seek 时有效速率一直为 0，播放中拖动时每步之间速率又会恢复，都不能以速率恢复判定落地，
    /// 只能看静默时长。只有 seek 跳变（`PlaybackTimebaseJump.isSeek`）重新计时，音频时钟重新锚定的
    /// 跳变不算。代价是单次 seek（键盘、评论时间戳）后弹幕最多晚这么久整屏对齐，而缓冲通常比它更长。
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
