import CoreMedia
import Dispatch
import Foundation
import QuartzCore
import Synchronization
import Testing

@testable import BiliKit

/// 固定弹幕时钟层的契约：每次速率变化或时间跳变之后本地时间与绑定 timebase 的时间一致（播放、暂停、跳
/// 时间、倍速），主线程被挡住时照样停下，绑定时不等通知就同步，换绑后旧 timebase 的变化不影响时钟层，
/// 解绑后停在速率 0、读不到弹幕时间；与其他线程的 Core Animation 提交并发时不死锁；其他线程按发布值求出
/// 的弹幕时间与 Core Animation 换算的本地时间是同一条线，从未绑定时读不到，换绑立即作废旧发布值，每次
/// 写入之后都会唤醒主线程读到它。
///
/// 用以宿主时钟为源的真实 `CMTimebase`，它的通知与播放器 item 的 timebase 走同一条路径。时钟层的更新
/// 在后台队列上异步落地，所以每次改变 timebase 之后等到时钟层与它一致；同时比对此刻与
/// `lookahead` 秒之后的宿主时间，一并证明速率，不需要等真实时间流逝。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct DanmakuTimebaseClockTests {
    /// 本地时间与 timebase 时间的容差（秒）：两者按同一个宿主时间换算，只差浮点与 CMTime 取整误差。
    private static let tolerance = 1e-3
    /// 额外比对的未来宿主时间偏移（秒）：速率差 0.01 在这里就是 0.1 秒，远大于容差。
    private static let lookahead = 10.0
    /// 与后台提交并发的时钟写入次数：未修正时几百次之内就会死锁。
    private static let concurrentCommitRounds = 2_000
    /// 主线程忙等时钟层停下的上限（秒），只作超时；正常在 timebase 停下后 1ms 内完成。
    private static let blockedMainThreadTimeout = 2.0

    @Test
    func bindingSynchronizesImmediatelyWithoutWaitingForANotification() async throws {
        let timebase = try makeTimebase(time: 5, rate: 0)
        let clock = DanmakuTimebaseClock()

        clock.bind(timebase)

        #expect(await converges(clock, to: timebase))
    }

    @Test
    func clockFollowsPlayPauseJumpAndRateChanges() async throws {
        let timebase = try makeTimebase(time: 0, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetRate(timebase, rate: 1)
        #expect(await converges(clock, to: timebase))

        // 暂停：此刻与将来的本地时间都等于冻结的 timebase 时间。
        CMTimebaseSetRate(timebase, rate: 0)
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 42, preferredTimescale: 600))
        #expect(await converges(clock, to: timebase))

        CMTimebaseSetRate(timebase, rate: 2)
        #expect(await converges(clock, to: timebase))

        // 播放中跳时间：速率保持，时间换到新位置。
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 7, preferredTimescale: 600))
        #expect(await converges(clock, to: timebase))
    }

    @Test
    func rebindingIgnoresTheOldTimebase() async throws {
        let old = try makeTimebase(time: 3, rate: 0)
        let new = try makeTimebase(time: 7, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(old)
        #expect(await converges(clock, to: old))
        clock.bind(new)
        #expect(await converges(clock, to: new))

        CMTimebaseSetRate(old, rate: 1)
        CMTimebaseSetTime(old, time: CMTime(seconds: 100, preferredTimescale: 600))
        // 时钟的同步按投递顺序串行执行：新 timebase 的这次变化落地时，旧 timebase 可能引起的同步都已处理完，
        // 而它们读的都是当前绑定的新 timebase。
        CMTimebaseSetTime(new, time: CMTime(seconds: 9, preferredTimescale: 600))

        #expect(await converges(clock, to: new))
    }

    @Test
    func neverBoundClockHasNoDisplayTime() {
        #expect(DanmakuTimebaseClock().displayTime() == nil)
    }

    /// 发布值求出的弹幕时间夹在读取前后两个宿主时间的 Core Animation 本地时间之间。
    @Test
    func publishedDisplayTimeIsTheClockLayersLine() async throws {
        let timebase = try makeTimebase(time: 20, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))
        #expect(await waitUntil { publishedTimeMatchesTheLayer(clock) })

        CMTimebaseSetRate(timebase, rate: 2)
        #expect(await converges(clock, to: timebase))
        #expect(await waitUntil { publishedTimeMatchesTheLayer(clock) })
    }

    /// 解绑之后没有 item 也就没有弹幕时间：时钟层停住，发布值一直读不到，不会冒充下一个视频的时间。
    @Test
    func unbindingLeavesNoDisplayTime() async throws {
        let timebase = try makeTimebase(time: 300, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await waitUntil { clock.displayTime() != nil })

        clock.bind(nil)
        #expect(clock.displayTime() == nil)
        #expect(await waitUntil { clock.layer.speed == 0 })

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 5, preferredTimescale: 600))
        #expect(clock.displayTime() == nil)
    }

    /// 换绑立即作废旧 timebase 的发布值；新 timebase 第一次写入后才有读数。
    @Test
    func rebindingInvalidatesThePublishedTimeUntilTheNewTimebaseWrites() async throws {
        let old = try makeTimebase(time: 100, rate: 1)
        let new = try makeTimebase(time: 5, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(old)
        #expect(await waitUntil { clock.displayTime() != nil })

        clock.bind(new)
        #expect(clock.displayTime() == nil)

        #expect(await waitUntil { clock.displayTime() != nil })
        #expect(abs((clock.displayTime() ?? 0) - 5) < Self.tolerance)
    }

    /// 每次写入之后都有一次唤醒，唤醒时读到的已是这次写入：暂停中跳时间之后不需要别的触发。
    @Test
    func everyWriteIsFollowedByAWakeThatSeesIt() async throws {
        let timebase = try makeTimebase(time: 20, rate: 0)
        let clock = DanmakuTimebaseClock()
        let wakes = WakeRecorder()
        clock.setWriteHandler { [weak clock] in wakes.record(clock?.displayTime()) }
        clock.bind(timebase)
        #expect(await waitUntil { abs((wakes.lastSeen ?? 0) - 20) < Self.tolerance })

        for target in [42.0, 7, 300] {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: target, preferredTimescale: 600))
            #expect(await waitUntil { abs((wakes.lastSeen ?? 0) - target) < Self.tolerance })
        }
    }

    /// 主线程被挡住时，时钟层照样在 timebase 停下的时刻停下。
    ///
    /// 模拟暂停时主线程被播放器挡住：后台线程把速率设为 0，主线程等它返回之后一直忙等、不让出。时钟层的
    /// 同步不经过主线程，所以在主线程恢复之前就已停下；同步若依赖主线程，这里会超时。
    @Test
    func clockStopsWhileTheMainThreadIsBlocked() async throws {
        let timebase = try makeTimebase(time: 5, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        pauseWithoutYieldingTheMainThread(timebase, clock: clock)

        #expect(clock.layer.speed == 0)
        #expect(matches(clock, timebase))
    }

    /// 时钟写入与别的线程的 Core Animation 提交并发时不死锁。
    ///
    /// 时钟队列写时钟层的同时，另一条线程不停提交事务（AppKit 在显示链接线程上推进动画就是这样），主线程同时
    /// 读本地时间：三方都能继续。持着全局锁提交会与对方反序加锁而死锁，这里会卡住。
    @Test
    func clockWritesDoNotDeadlockWithAnotherThreadsCommits() async throws {
        let timebase = try makeTimebase(time: 0, rate: 0)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))
        let committer = BackgroundCommitter()
        committer.start()
        defer { committer.stop() }

        for step in 0..<Self.concurrentCommitRounds {
            CMTimebaseSetTime(timebase, time: CMTime(value: CMTimeValue(step), timescale: 600))
            _ = clock.layer.convertTime(CACurrentMediaTime(), from: nil)
        }

        #expect(await converges(clock, to: timebase))
    }

    @Test
    func unbindingStopsTheClock() async throws {
        let timebase = try makeTimebase(time: 4, rate: 1)
        let clock = DanmakuTimebaseClock()
        clock.bind(timebase)
        #expect(await converges(clock, to: timebase))

        clock.bind(nil)

        #expect(await waitUntil { clock.layer.speed == 0 })
        let now = CACurrentMediaTime()
        let local = clock.layer.convertTime(now, from: nil)
        #expect(clock.layer.convertTime(now + Self.lookahead, from: nil) == local)
    }

    /// 在一条后台线程上不停提交改自己 layer 的显式事务，直到 `stop`。
    private final class BackgroundCommitter: Sendable {
        private let isStopped = Atomic<Bool>(false)

        func start() {
            Thread { [self] in
                let layer = CALayer()
                var opacity: Float = 0
                while !isStopped.load(ordering: .acquiring) {
                    opacity = opacity < 1 ? opacity + 0.01 : 0
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.opacity = opacity
                    CATransaction.commit()
                }
            }.start()
        }

        func stop() {
            isStopped.store(true, ordering: .releasing)
        }
    }

    /// 记录每次写入通知时读到的弹幕时间。
    @MainActor
    private final class WakeRecorder {
        private(set) var lastSeen: Double?

        func record(_ seconds: Double?) {
            lastSeen = seconds
        }
    }

    /// 此刻读到的发布值，落在读取前后两个宿主时间的 Core Animation 本地时间之间。
    private func publishedTimeMatchesTheLayer(_ clock: DanmakuTimebaseClock) -> Bool {
        let before = CACurrentMediaTime()
        guard let published = clock.displayTime() else { return false }
        let after = CACurrentMediaTime()
        return published >= clock.layer.convertTime(before, from: nil) - Self.tolerance
            && published <= clock.layer.convertTime(after, from: nil) + Self.tolerance
    }

    private func makeTimebase(time: Double, rate: Double) throws -> CMTimebase {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        let created = try #require(status == noErr ? timebase : nil)
        CMTimebaseSetTime(created, time: CMTime(seconds: time, preferredTimescale: 600))
        CMTimebaseSetRate(created, rate: rate)
        return created
    }

    /// 等到时钟层与 timebase 一致。
    private func converges(_ clock: DanmakuTimebaseClock, to timebase: CMTimebase) async -> Bool {
        await waitUntil { matches(clock, timebase) }
    }

    /// 时钟层在此刻与 `lookahead` 秒之后的本地时间都等于 timebase 在同一宿主时间的时间。
    private func matches(_ clock: DanmakuTimebaseClock, _ timebase: CMTimebase) -> Bool {
        let host = CACurrentMediaTime()
        return [0, Self.lookahead].allSatisfy { offset in
            let expected = CMSyncConvertTime(
                CMTime(seconds: host + offset, preferredTimescale: 1_000_000_000),
                from: CMClockGetHostTimeClock(),
                to: timebase
            ).seconds
            let local = clock.layer.convertTime(host + offset, from: nil)
            return abs(local - expected) < Self.tolerance
        }
    }

    /// 在后台线程把速率设为 0 并等它返回，然后在主线程上忙等时钟层停下，期间不让出主线程。
    private func pauseWithoutYieldingTheMainThread(
        _ timebase: CMTimebase,
        clock: DanmakuTimebaseClock
    ) {
        let paused = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            CMTimebaseSetRate(timebase, rate: 0)
            paused.signal()
        }
        paused.wait()
        let deadline = CACurrentMediaTime() + Self.blockedMainThreadTimeout
        while clock.layer.speed != 0, CACurrentMediaTime() < deadline {}
    }
}
