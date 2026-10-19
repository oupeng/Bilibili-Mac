@preconcurrency import AVFoundation
import BiliApplication
import CoreMedia
import Foundation
import Synchronization
import Testing

@testable import BiliPlayback

/// 固定时间线的 seek 阶段契约：只有速率为 0 的 timebase 跳变（seek）进入 seeking，最后一次 seek 跳变
/// 之后静默满时限才落地一次，落点取 timebase 时间；音频时钟重新锚定的跳变（速率大于 0）、开播、继续
/// 播放与改速率都不是 seek；换 item、失败与 clear 取消落地计时并回到 settled。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackSeekLandingTests {
    @Test
    func seekJumpEntersSeekingAtTheJumpTarget() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let before = timeline.currentSnapshot
        let timebase = try makeTimebase(at: 42)

        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)

        #expect(timeline.currentSnapshot.seekPhase == .seeking)
        #expect(timeline.currentSnapshot.positionSeconds == 42)
        #expect(timeline.currentSnapshot.landingGeneration == before.landingGeneration)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration
                == before.discontinuityGeneration
        )
        try await clock.waitForSleepRequests(1)
        #expect(clock.requestedSleeps == [PlaybackSeekLandingTimer.quietInterval])
    }

    /// 速率大于 0 的跳变是音频时钟重新锚定：不进入 seeking；seeking 期间到达时也不刷新落地计时。
    @Test
    func reanchoringJumpIsNotASeek() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let landings = LandingRecorder(timeline)
        let timebase = try makeTimebase(at: 12)
        let before = timeline.currentSnapshot

        timeline.observeTimebaseJump(
            PlaybackTimebaseJump(positionSeconds: 11.96, rate: 1),
            on: timebase
        )
        #expect(timeline.currentSnapshot == before)

        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        try await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval - .milliseconds(1))
        timeline.observeTimebaseJump(
            PlaybackTimebaseJump(positionSeconds: 11.95, rate: 2),
            on: timebase
        )
        clock.advance(by: .milliseconds(1))
        let landed = try await landings.next()

        #expect(clock.requestedSleeps.count == 1)
        #expect(landed.landingGeneration == before.landingGeneration + 1)
        #expect(landings.count == 1)
    }

    /// 拖动：跳变之间不足静默时限时一直是 seeking，最后一次之后满时限才落地，且只落地一次。
    @Test
    func consecutiveJumpsLandOnceAfterTheLastQuietInterval() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let landings = LandingRecorder(timeline)
        let before = timeline.currentSnapshot.landingGeneration
        let timebase = try makeTimebase(at: 10)
        let almostQuiet = PlaybackSeekLandingTimer.quietInterval - .milliseconds(1)

        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        try await clock.waitForSleepRequests(1)
        clock.advance(by: almostQuiet)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 20, preferredTimescale: 600))
        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        try await clock.waitForSleepRequests(2)
        clock.advance(by: almostQuiet)

        #expect(timeline.currentSnapshot.seekPhase == .seeking)
        #expect(clock.pendingSleepCount == 1)

        clock.advance(by: .milliseconds(1))
        let landed = try await landings.next()

        #expect(landed.landingGeneration == before + 1)
        #expect(landed.seekPhase == .settled)
        #expect(landed.positionSeconds == 20)
        #expect(landings.count == 1)
    }

    /// 落点是落地时刻的 timebase 时间，而不是第一次跳变时读到的位置。
    @Test
    func landingPositionIsTheTimebaseTimeAtLanding() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let landings = LandingRecorder(timeline)
        let timebase = try makeTimebase(at: 30)

        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 30.25, preferredTimescale: 600))
        try await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)

        #expect(try await landings.next().positionSeconds == 30.25)
    }

    /// clear、换 item 与失败取消在途的落地计时并回到 settled；clear 与换 item 各算一次落地，失败不算。
    @Test(arguments: ["clear", "replace", "fail"])
    func endingTheItemCancelsThePendingLanding(ending: String) async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let timebase = try makeTimebase(at: 8)
        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        try await clock.waitForSleepRequests(1)
        let seekingGeneration = timeline.currentSnapshot.landingGeneration

        switch ending {
        case "replace":
            timeline.begin(identity: PlaybackItemIdentity(bvid: "BVSeekReplace", cid: 2))
        case "fail":
            timeline.markFailed()
        default:
            timeline.clear()
        }

        #expect(clock.pendingSleepCount == 0)
        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(
            timeline.currentSnapshot.landingGeneration
                == seekingGeneration + (ending == "fail" ? 0 : 1)
        )
    }

    /// 加载中的跳变是起播位置就位，不算 seek；续播起点在就绪时算一次落地。
    @Test
    func loadingJumpIsIgnoredAndResumeStartLandsOnReady() throws {
        let clock = ManualClock()
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer(), landingClock: clock)
        timeline.begin(
            identity: PlaybackItemIdentity(bvid: "BVSeekResume", cid: 1),
            startPositionSeconds: 42
        )
        let begun = timeline.currentSnapshot.landingGeneration
        let timebase = try makeTimebase(at: 42)

        timeline.observeTimebaseJump(seekJump(on: timebase), on: timebase)
        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(clock.pendingSleepCount == 0)

        timeline.markReady(duration: CMTime(seconds: 100, preferredTimescale: 600))
        #expect(timeline.currentSnapshot.landingGeneration == begun + 1)
    }

    /// 通知桥接：设定 timebase 时间发出跳变，并带上那一刻的时间与速率；单纯改速率不发；移除 observer
    /// 之后不再回调。
    @Test
    func timebaseObserverReportsJumpsWithTheirRate() throws {
        let timebase = try makeTimebase(at: 0)
        let jumps = Mutex<[PlaybackTimebaseJump]>([])
        let observer = PlaybackTimebaseJumps.observe(timebase) { jump in
            jumps.withLock { $0.append(jump) }
        }

        CMTimebaseSetRate(timebase, rate: 1)
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseNotificationBarrier(timebase)
        #expect(jumps.withLock { $0 }.isEmpty)

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 5, preferredTimescale: 600))
        CMTimebaseSetRateAndAnchorTime(
            timebase,
            rate: 2,
            anchorTime: CMTime(seconds: 7, preferredTimescale: 600),
            immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock())
        )
        CMTimebaseNotificationBarrier(timebase)
        let reported = jumps.withLock { $0 }
        #expect(reported.map(\.rate) == [0, 2])
        #expect(reported.map(\.isSeek) == [true, false])
        #expect(reported.first?.positionSeconds == 5)

        NotificationCenter.default.removeObserver(observer)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 9, preferredTimescale: 600))
        CMTimebaseNotificationBarrier(timebase)
        #expect(jumps.withLock { $0 }.count == 2)
    }

    /// 真实 AVPlayer 与带音轨的媒体：暂停中 seek 经 item timebase 进入 seeking 并落地一次；之后开播、
    /// 暂停后继续与改速率都不进入 seeking；播放中 seek 只落地一次。
    @Test(.timeLimit(.minutes(1)))
    func audioPlayerSeeksLandOnceAndPlaybackChangesDoNot() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "audio-aac",
                withExtension: "mp4",
                subdirectory: "Fixtures"
            )
        )
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let clock = ManualClock()
        let timeline = AVPlayerTimelineAdapter(player: player, landingClock: clock)
        timeline.begin(identity: PlaybackItemIdentity(bvid: "BVSeekPlayer", cid: 1))
        timeline.installObservers(for: item)
        try await AVPlayerItemReadiness.wait(untilReady: item)
        timeline.markReady(duration: item.duration)
        let timebase = try #require(item.timebase)
        let landings = LandingRecorder(timeline)
        let seekPhases = SeekPhaseRecorder(timeline)
        let reanchors = ReanchorWaiter(timebase)
        defer { reanchors.stop() }

        // 暂停中 seek：进入 seeking，落地一次。
        await player.seek(
            to: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        await drainTimebaseNotifications(timebase)
        #expect(seekPhases.seekingCount == 1)
        try await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)
        #expect(try await landings.next().positionSeconds == 0.5)

        // 开播、暂停后继续、改速率：系统各发一次重新锚定的跳变，都不算 seek。
        timeline.play()
        try await reanchors.next()
        // 起步之前就暂停时，系统会以速率 0 把时间设回起播点，那是一次真实的时间设定；这里等播放
        // 确实走过起播点再暂停，固定的是“正常播放中暂停后继续”。
        try await waitUntilPlaying(timebase, beyond: 0.6)
        timeline.pause()
        try await waitUntilStopped(timebase)
        timeline.play()
        try await reanchors.next()
        try timeline.setRate(1.5)
        try await reanchors.next()
        await drainTimebaseNotifications(timebase)
        #expect(seekPhases.seekingCount == 1)
        #expect(clock.pendingSleepCount == 0)
        #expect(landings.count == 1)

        // 播放中 seek：seek 跳变之后的重新锚定不刷新计时，只落地一次。
        player.seek(
            to: CMTime(seconds: 0.2, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { _ in }
        try await reanchors.next()
        await drainTimebaseNotifications(timebase)
        try await clock.waitForSleepRequests(2)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)
        _ = try await landings.next()
        timeline.pause()

        #expect(seekPhases.seekingCount == 2)
        #expect(clock.requestedSleeps.count == 2)
        #expect(landings.count == 2)
    }

    private func makeReadyTimeline(clock: ManualClock) -> AVPlayerTimelineAdapter {
        let timeline = AVPlayerTimelineAdapter(player: AVPlayer(), landingClock: clock)
        timeline.begin(identity: PlaybackItemIdentity(bvid: "BVSeekLanding", cid: 1))
        timeline.markReady(duration: CMTime(seconds: 100, preferredTimescale: 600))
        return timeline
    }

    private func makeTimebase(at seconds: Double) throws -> CMTimebase {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: nil,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        let created = try #require(status == noErr ? timebase : nil)
        CMTimebaseSetTime(created, time: CMTime(seconds: seconds, preferredTimescale: 600))
        return created
    }

    /// seek 时系统给出的跳变：速率为 0，位置为 timebase 当前时间。
    private func seekJump(on timebase: CMTimebase) -> PlaybackTimebaseJump {
        PlaybackTimebaseJump(positionSeconds: CMTimebaseGetTime(timebase).seconds, rate: 0)
    }

    /// 等 timebase 发完已产生的通知，并让它们切回主线程的处理先于之后的断言执行。
    private func drainTimebaseNotifications(_ timebase: CMTimebase) async {
        CMTimebaseNotificationBarrier(timebase)
        // 已发出的通知都已切回主线程排队；这个 Task 排在它们之后。
        await Task { @MainActor in }.value
    }

    /// 等到 timebase 的有效速率归零，暂停才真正生效；没有事件可等，按条件轮询，时限由 Suite 兜底。
    private func waitUntilStopped(_ timebase: CMTimebase) async throws {
        while CMTimebaseGetEffectiveRate(timebase) > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 等到 timebase 以正速率走过 `seconds`；没有事件可等，按条件轮询，时限由 Suite 兜底。
    private func waitUntilPlaying(_ timebase: CMTimebase, beyond seconds: Double) async throws {
        while CMTimebaseGetEffectiveRate(timebase) <= 0
            || CMTimebaseGetTime(timebase).seconds <= seconds
        {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// 在测试一侧另行订阅同一 timebase，按顺序给出系统的重新锚定跳变（速率大于 0）。
///
/// 只用来知道「系统已经发过这次重新锚定」，之后再排空通知、断言时间线没有进入 seeking；被取消（Suite
/// 超时）时结束等待。测试结束时调用 `stop` 移除 observer。
@MainActor
private final class ReanchorWaiter {
    private let observer: NSObjectProtocol
    private let jumps: AsyncStream<PlaybackTimebaseJump>

    init(_ timebase: CMTimebase) {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackTimebaseJump.self)
        jumps = stream
        observer = PlaybackTimebaseJumps.observe(timebase) { jump in
            if !jump.isSeek {
                continuation.yield(jump)
            }
        }
    }

    /// 一次只由一个调用方等待；流里已缓存的跳变按到达顺序依次给出。
    func next() async throws {
        var iterator = jumps.makeAsyncIterator()
        let jump = await iterator.next()
        try Task.checkCancellation()
        _ = try #require(jump)
    }

    func stop() {
        NotificationCenter.default.removeObserver(observer)
    }
}

/// 同步记录时间线进入 seeking 的次数。
@MainActor
private final class SeekPhaseRecorder {
    private(set) var seekingCount = 0

    init(_ timeline: AVPlayerTimelineAdapter) {
        var lastPhase = timeline.currentSnapshot.seekPhase
        _ = timeline.observe { [weak self] snapshot in
            defer { lastPhase = snapshot.seekPhase }
            if snapshot.seekPhase == .seeking, lastPhase == .settled {
                self?.seekingCount += 1
            }
        }
    }
}

/// 同步记录时间线上每一次落地（`landingGeneration` 增加），并可等待下一次。
@MainActor
private final class LandingRecorder {
    private(set) var landings: [PlaybackTimelineSnapshot] = []
    private var consumed = 0
    private var waiter: CheckedContinuation<PlaybackTimelineSnapshot, any Error>?

    var count: Int { landings.count }

    init(_ timeline: AVPlayerTimelineAdapter) {
        var lastGeneration = timeline.currentSnapshot.landingGeneration
        _ = timeline.observe { [weak self] snapshot in
            guard snapshot.landingGeneration != lastGeneration else { return }
            lastGeneration = snapshot.landingGeneration
            self?.record(snapshot)
        }
    }

    /// 等下一次落地；被取消（例如 Suite 超时）时抛出 `CancellationError`，测试失败而不是挂住。
    func next() async throws -> PlaybackTimelineSnapshot {
        if consumed < landings.count {
            consumed += 1
            return landings[consumed - 1]
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiter?.resume(throwing: CancellationError())
                self?.waiter = nil
            }
        }
    }

    private func record(_ snapshot: PlaybackTimelineSnapshot) {
        landings.append(snapshot)
        guard let waiter else { return }
        self.waiter = nil
        consumed += 1
        waiter.resume(returning: snapshot)
    }
}

/// 手动推进的时钟。
///
/// `advance(by:)` 推进时间并放行到期的 sleep；被取消的 sleep 立即以 `CancellationError` 结束。记录
/// 每次请求的时长，`waitForSleepRequests` 等到计时 Task 真正开始等待，之后推进时间才有意义。
private final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        let offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
        var requestedSleeps: [Swift.Duration] = []
        var requestWaiters:
            [(id: UUID, count: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }
    var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }
    var requestedSleeps: [Swift.Duration] { state.withLock { $0.requestedSleeps } }

    /// 等到累计收到 `count` 次 sleep 请求；被取消（例如 Suite 超时）时抛出 `CancellationError`。
    func waitForSleepRequests(_ count: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate: Result<Void, any Error>? = state.withLock { state in
                    if state.requestedSleeps.count >= count { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    state.requestWaiters.append((id, count, continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state in
                state.requestWaiters.firstIndex { $0.id == id }
                    .map { state.requestWaiters.remove(at: $0) }
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (immediate, readyWaiters) = state.withLock {
                    state -> (Result<Void, any Error>?, [CheckedContinuation<Void, any Error>]) in
                    state.requestedSleeps.append(state.now.duration(to: deadline))
                    let requested = state.requestedSleeps.count
                    let ready = state.requestWaiters.filter { $0.count <= requested }
                    state.requestWaiters.removeAll { $0.count <= requested }
                    let waiters = ready.map(\.continuation)
                    if Task.isCancelled { return (.failure(CancellationError()), waiters) }
                    if deadline <= state.now { return (.success(()), waiters) }
                    state.sleepers.append(
                        Sleeper(id: id, deadline: deadline, continuation: continuation)
                    )
                    return (nil, waiters)
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
                for waiter in readyWaiters {
                    waiter.resume()
                }
            }
        } onCancel: {
            let cancelled = state.withLock { state in
                state.sleepers.firstIndex { $0.id == id }.map { state.sleepers.remove(at: $0) }
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Swift.Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.deadline <= now }
            state.sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
