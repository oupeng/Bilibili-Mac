import CoreMedia
import Dispatch
import QuartzCore
import Testing

@testable import BiliKit

/// 固定弹幕时钟层的契约：每次速率变化或时间跳变之后本地时间与绑定 timebase 的时间一致（播放、暂停、跳
/// 时间、倍速），主线程被挡住时照样停下，绑定时不等通知就同步，换绑后旧 timebase 的变化不影响时钟层，
/// 解绑后停在速率 0。
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
