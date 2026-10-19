@preconcurrency import AVFoundation
import BiliApplication
import CoreMedia
import Foundation
import Synchronization
import Testing

@testable import BiliPlayback

/// 固定时间线的 seek 阶段契约：只有 timebase 跳变进入 seeking，最后一次跳变之后静默满时限才落地一次，
/// 落点取 timebase 时间；速率变化与开播不是跳变；换 item、失败与 clear 取消落地计时。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackSeekLandingTests {
    @Test
    func timebaseJumpEntersSeekingAtTheJumpTarget() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let before = timeline.currentSnapshot
        let timebase = try makeTimebase(at: 42)

        timeline.observeTimebaseJump(on: timebase)

        #expect(timeline.currentSnapshot.seekPhase == .seeking)
        #expect(timeline.currentSnapshot.positionSeconds == 42)
        #expect(timeline.currentSnapshot.landingGeneration == before.landingGeneration)
        #expect(
            timeline.currentSnapshot.discontinuityGeneration
                == before.discontinuityGeneration
        )
        await clock.waitForSleepRequests(1)
        #expect(clock.requestedSleeps == [PlaybackSeekLandingTimer.quietInterval])
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

        timeline.observeTimebaseJump(on: timebase)
        await clock.waitForSleepRequests(1)
        clock.advance(by: almostQuiet)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 20, preferredTimescale: 600))
        timeline.observeTimebaseJump(on: timebase)
        await clock.waitForSleepRequests(2)
        clock.advance(by: almostQuiet)

        #expect(timeline.currentSnapshot.seekPhase == .seeking)
        #expect(clock.pendingSleepCount == 1)

        clock.advance(by: .milliseconds(1))
        let landed = await landings.next()

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

        timeline.observeTimebaseJump(on: timebase)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 30.25, preferredTimescale: 600))
        await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)

        #expect(await landings.next().positionSeconds == 30.25)
    }

    /// 暂停中 seek 落地后，开播与改速率都不是跳变：不重新进入 seeking，也不再落地。
    @Test
    func playbackStartAndRateChangesAfterLandingDoNotLandAgain() async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        let landings = LandingRecorder(timeline)
        timeline.pause()
        timeline.observeTimebaseJump(on: try makeTimebase(at: 12))
        await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)
        let landed = await landings.next()

        timeline.play()
        try timeline.setRate(2)

        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(timeline.currentSnapshot.landingGeneration == landed.landingGeneration)
        #expect(clock.pendingSleepCount == 0)
        #expect(landings.count == 1)
    }

    /// clear 与换 item 取消在途的落地计时并回到 settled；它们自己各算一次落地。
    @Test(arguments: [true, false])
    func clearAndItemReplacementCancelThePendingLanding(replacesItem: Bool) async throws {
        let clock = ManualClock()
        let timeline = makeReadyTimeline(clock: clock)
        timeline.observeTimebaseJump(on: try makeTimebase(at: 8))
        await clock.waitForSleepRequests(1)
        let seekingGeneration = timeline.currentSnapshot.landingGeneration

        if replacesItem {
            timeline.begin(identity: PlaybackItemIdentity(bvid: "BVSeekReplace", cid: 2))
        } else {
            timeline.clear()
        }

        #expect(clock.pendingSleepCount == 0)
        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(timeline.currentSnapshot.landingGeneration == seekingGeneration + 1)
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

        timeline.observeTimebaseJump(on: try makeTimebase(at: 42))
        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(clock.pendingSleepCount == 0)

        timeline.markReady(duration: CMTime(seconds: 100, preferredTimescale: 600))
        #expect(timeline.currentSnapshot.landingGeneration == begun + 1)
    }

    /// 通知桥接：设定 timebase 时间发出跳变，改速率不发；移除 observer 之后不再回调。
    @Test
    func timebaseObserverReportsTimeJumpsButNotRateChanges() throws {
        let timebase = try makeTimebase(at: 0)
        let jumps = Mutex(0)
        let observer = PlaybackTimebaseJumps.observe(timebase) {
            jumps.withLock { $0 += 1 }
        }

        CMTimebaseSetRate(timebase, rate: 1)
        CMTimebaseSetRate(timebase, rate: 2)
        CMTimebaseSetRate(timebase, rate: 0)
        CMTimebaseNotificationBarrier(timebase)
        #expect(jumps.withLock { $0 } == 0)

        CMTimebaseSetTime(timebase, time: CMTime(seconds: 5, preferredTimescale: 600))
        CMTimebaseNotificationBarrier(timebase)
        #expect(jumps.withLock { $0 } == 1)

        NotificationCenter.default.removeObserver(observer)
        CMTimebaseSetTime(timebase, time: CMTime(seconds: 9, preferredTimescale: 600))
        CMTimebaseNotificationBarrier(timebase)
        #expect(jumps.withLock { $0 } == 1)
    }

    /// 真实 AVPlayer：暂停中 seek 经 item timebase 通知进入 seeking 并落在目标处；之后开播不再落地。
    @Test(.timeLimit(.minutes(1)))
    func pausedPlayerSeekLandsThroughTheItemTimebase() async throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "video-avc",
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
        let landings = LandingRecorder(timeline)
        let seeking = SnapshotWaiter(timeline) { $0.seekPhase == .seeking }

        await player.seek(
            to: CMTime(seconds: 1, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        #expect(await seeking.value.positionSeconds == 1)
        await clock.waitForSleepRequests(1)
        clock.advance(by: PlaybackSeekLandingTimer.quietInterval)
        #expect(await landings.next().positionSeconds == 1)

        player.play()
        let timebase = try #require(item.timebase)
        try await waitUntil { CMTimebaseGetEffectiveRate(timebase) > 0 }
        CMTimebaseNotificationBarrier(timebase)
        // 已发出的通知都已切回主线程排队；这个 Task 排在它们之后。
        await Task { @MainActor in }.value
        player.pause()

        #expect(timeline.currentSnapshot.seekPhase == .settled)
        #expect(clock.pendingSleepCount == 0)
        #expect(landings.count == 1)
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

    /// 轮询一个由系统异步改变、没有事件可等的条件；时限由 Suite 的 timeLimit 兜底。
    private func waitUntil(_ condition: () -> Bool) async throws {
        while !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// 同步记录时间线上每一次落地（`landingGeneration` 增加），并可等待下一次。
@MainActor
private final class LandingRecorder {
    private(set) var landings: [PlaybackTimelineSnapshot] = []
    private var consumed = 0
    private var waiter: CheckedContinuation<PlaybackTimelineSnapshot, Never>?

    var count: Int { landings.count }

    init(_ timeline: AVPlayerTimelineAdapter) {
        var lastGeneration = timeline.currentSnapshot.landingGeneration
        _ = timeline.observe { [weak self] snapshot in
            guard snapshot.landingGeneration != lastGeneration else { return }
            lastGeneration = snapshot.landingGeneration
            self?.record(snapshot)
        }
    }

    func next() async -> PlaybackTimelineSnapshot {
        if consumed < landings.count {
            consumed += 1
            return landings[consumed - 1]
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    private func record(_ snapshot: PlaybackTimelineSnapshot) {
        landings.append(snapshot)
        guard let waiter else { return }
        self.waiter = nil
        consumed += 1
        waiter.resume(returning: snapshot)
    }
}

/// 等到时间线发布第一个满足条件的快照。
@MainActor
private final class SnapshotWaiter {
    private var matched: PlaybackTimelineSnapshot?
    private var waiter: CheckedContinuation<PlaybackTimelineSnapshot, Never>?

    init(
        _ timeline: AVPlayerTimelineAdapter,
        where predicate: @escaping @MainActor (PlaybackTimelineSnapshot) -> Bool
    ) {
        _ = timeline.observe { [weak self] snapshot in
            guard let self, self.matched == nil, predicate(snapshot) else { return }
            self.matched = snapshot
            self.waiter?.resume(returning: snapshot)
            self.waiter = nil
        }
    }

    var value: PlaybackTimelineSnapshot {
        get async {
            if let matched { return matched }
            return await withCheckedContinuation { waiter = $0 }
        }
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
        var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }
    var pendingSleepCount: Int { state.withLock { $0.sleepers.count } }
    var requestedSleeps: [Swift.Duration] { state.withLock { $0.requestedSleeps } }

    /// 等到累计收到 `count` 次 sleep 请求。
    func waitForSleepRequests(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let isReady = state.withLock { state in
                guard state.requestedSleeps.count < count else { return true }
                state.requestWaiters.append((count, continuation))
                return false
            }
            if isReady {
                continuation.resume()
            }
        }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (immediate, readyWaiters) = state.withLock {
                    state -> (Result<Void, any Error>?, [CheckedContinuation<Void, Never>]) in
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
