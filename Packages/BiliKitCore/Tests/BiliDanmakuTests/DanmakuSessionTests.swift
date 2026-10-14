import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 会话本身不可观察，测试只经产品出口判断：repository 收到的请求、presentation sink 收到的更新与
/// 认证失效回调。
///
/// 分段结果写回的确定性信号是「后续分段被请求」：会话同时最多加载两段，补位窗口让想要的分段多于两段，
/// 新分段只能在已发出的加载有结果写回（成功入缓存或失败记下）、释放名额之后才被请求。成功结果若没进缓存、
/// 失败若没被记下，释放的名额会先用来重新请求同一段，所以「请求的分段各不相同」同时证明了写回；
/// 名额不释放时不会再有请求，由 timeLimit 判失败。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionTests {
    /// 补位窗口 10 秒时，这个位置想要的分段依次是当前第 2 段、上一段第 1 段、下一段第 3 段。
    nonisolated private static let threeSegmentPosition = 365.0
    /// 同样窗口下想要第 3、2、4 段；第 1～3 段都已请求后，第 4 段被请求说明其中至多一段仍在加载。
    nonisolated private static let laterThreeSegmentPosition = 725.0
    nonisolated private static let threeSegmentCatchUpWindowSeconds = 10.0

    @Test
    func sessionPrefetchesCurrentAndNextWithBoundedConcurrency() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 1)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2])
        #expect(await repository.maximumActiveRequests() == 2)
        session.stop()
        await repository.releaseAll()
    }

    /// 会话把呈现端给出的补位窗口交给调度：窗口跨进上一分段时先请求当前与上一分段，
    /// 没有窗口时请求当前与下一分段。
    @Test(arguments: [
        (DanmakuSessionTests.threeSegmentCatchUpWindowSeconds, [1, 2]),
        (0.0, [2, 3])
    ])
    func sessionUsesThePresentationCatchUpWindowForSegmentRequests(
        catchUpWindowSeconds: Double,
        expectedIndices: [Int]
    ) async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1CatchUpWindow", cid: 4)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        sink.catchUpWindowSeconds = catchUpWindowSeconds
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: identity)
        timeline.publish(
            snapshot(identity: identity, position: Self.threeSegmentPosition, generation: 1)
        )
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == expectedIndices)
        session.stop()
        await repository.releaseAll()
    }

    /// 成功的分段写回缓存并释放名额后，会话请求下一个想要的分段，且不重复请求已缓存的分段。
    ///
    /// 删掉写回缓存时第三次请求会是第 1 或第 2 段；名额不释放时不会再有请求，由 timeLimit 判失败。
    @Test
    func loadedSegmentsAreCachedAndFreeSlotsForTheNextWantedSegment() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1WriteBackFixture", cid: 8)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            2,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2])

        await repository.release(identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2, 3])
        session.stop()
    }

    @Test
    func replacingIdentityCancelsOldLoadsAndStopEndsTheSession() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: first)
        try await advanceUntilRequestCount(
            2,
            identity: first,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        session.start(for: second)
        try await repository.waitForCancellationCount(2, identity: first)
        await repository.release(first)
        try await advanceUntilRequestCount(
            2,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        // 新视频的分段照常写回并在名额释放后请求下一段；被取消的旧视频不再发起请求。
        await repository.release(second)
        try await advanceUntilRequestCount(
            3,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: second).sorted() == [1, 2, 3])
        #expect(await repository.requestCount(for: first) == 2)

        // stop 结束整个会话：退订时间线，之后的快照既不请求也不再交给呈现端。
        let updatesBeforeStop = sink.updateCount(for: second)
        session.stop()
        await timeline.waitForSubscriberCount(0)
        timeline.publish(
            snapshot(identity: second, position: Self.threeSegmentPosition, generation: 2)
        )
        #expect(await repository.requestCount(for: second) == 3)
        #expect(sink.updateCount(for: second) == updatesBeforeStop)
    }

    @Test
    func presentationSinkReceivesEveryAcceptedTimelineUpdate() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1PresentationFixture", cid: 3)
        let repository = StubDanmakuRepository()
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 0,
                state: .paused
            )
        )
        try await sink.waitForUpdateCount(1, identity: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 1,
                generation: 7,
                rate: 2,
                state: .playing
            )
        )
        try await sink.waitForUpdateCount(2, identity: identity)

        let accepted = sink.updates.filter {
            $0.snapshot.identity == identity
        }
        try #require(accepted.count == 2)
        #expect(accepted[0].snapshot.state == .paused)
        #expect(accepted[0].batch?.clearsExisting == true)
        #expect(accepted[1].snapshot.rate == 2)
        #expect(accepted[1].batch == nil)
    }

    @Test
    func controlsClearOrStopPresentationSynchronously() throws {
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: StubDanmakuRepository()),
            timeline: SessionTimeline(),
            presentationSink: sink
        )

        session.setEnabled(false)
        #expect(sink.clearCount == 1)

        session.setModeVisibility(scrolling: false, top: true, bottom: true)
        #expect(sink.clearCount == 2)

        session.setSpeedLevel(.five)
        session.setOpacity(try #require(DanmakuOpacity(0.55)))
        session.setDisplayArea(.quarter)
        session.setDensity(.overlapping)
        #expect(sink.clearCount == 2)

        session.stop()
        #expect(sink.stopCount == 1)
    }

    /// 失败的分段（含被风控拒绝的）在当前视频内不再请求。
    ///
    /// 412 的一次延迟重试由 API 客户端负责，会话不叠加。第 4 段被请求时，前三段至少两段的失败已写回；
    /// 若失败不被记住，释放的名额会先用来重新请求失败段，请求序列就会出现重复。
    @Test(arguments: [DanmakuApplicationError.unavailable, .requestRestricted])
    func failedSegmentsAreNotRetriedByLaterTimelineUpdates(
        error: DanmakuApplicationError
    ) async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1FailingDanmakuFixture",
            cid: 4
        )
        let repository = StubDanmakuRepository(.fail(error))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await advanceUntilRequestCount(
            4,
            identity: identity,
            generation: 1,
            position: Self.laterThreeSegmentPosition,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2, 3, 4])
        session.stop()
    }

    @Test
    func authenticationInvalidationIsReportedOncePerSession() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1AuthDanmakuFixture",
            cid: 40
        )
        let repository = StubDanmakuRepository(.fail(.authenticationInvalid))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)
        let invalidations = InvalidationRecorder()
        session.setAuthenticationInvalidationHandler {
            invalidations.record()
        }

        // 第 4 段被请求时，前三段至少两段的认证失效已处理；同一会话内回调只有一次。
        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await advanceUntilRequestCount(
            4,
            identity: identity,
            generation: 1,
            position: Self.laterThreeSegmentPosition,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(invalidations.count == 1)

        // 新会话重新允许回调一次。
        session.stop()
        session.start(for: identity)
        try await advanceUntilRequestCount(
            6,
            identity: identity,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        try await invalidations.wait(until: 2)
        session.stop()
    }

    /// 换视频时清空失败记录：第 3 段被请求说明第一个视频至少有一段失败已记下，再换到第二个视频。
    ///
    /// 若记录未清空，第二个视频永远不会请求那一段，等不到三次请求，由 timeLimit 判失败。
    @Test
    func failedSegmentMemoryIsClearedForReplacement() async throws {
        let first = PlaybackItemIdentity(
            bvid: "BV1FirstFailureFixture",
            cid: 5
        )
        let second = PlaybackItemIdentity(
            bvid: "BV1SecondFailureFixture",
            cid: 6
        )
        let repository = StubDanmakuRepository(.fail(.unavailable))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: first)
        try await advanceUntilRequestCount(
            3,
            identity: first,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        session.start(for: second)
        try await advanceUntilRequestCount(
            3,
            identity: second,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(await repository.requestedIndices(for: second).sorted() == [1, 2, 3])
        #expect(await repository.requestCount(for: first) == 3)
        session.stop()
    }

    /// stop 后重新开始同一视频时，上一轮失败的分段重新请求并恢复；失败同步方式同上。
    @Test
    func restartingSessionAllowsFailedSegmentsToRecover() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1RecoveringDanmakuFixture",
            cid: 7
        )
        let repository = StubDanmakuRepository(.failFirstAttemptPerSegment(.unavailable))
        let (session, timeline, sink) = makeThreeSegmentSession(repository: repository)

        session.start(for: identity)
        try await advanceUntilRequestCount(
            3,
            identity: identity,
            generation: 1,
            timeline: timeline,
            sink: sink,
            repository: repository
        )

        // 若失败记录未随 stop 清空，被记下的那段永远不会再请求，等不到六次请求，由 timeLimit 判失败。
        session.stop()
        session.start(for: identity)
        try await advanceUntilRequestCount(
            6,
            identity: identity,
            generation: 2,
            timeline: timeline,
            sink: sink,
            repository: repository
        )
        #expect(
            await repository.requestedIndices(for: identity).sorted() == [1, 1, 2, 2, 3, 3]
        )
        session.stop()
    }

    /// 补位窗口让想要的分段多于并发上限的会话。
    private func makeThreeSegmentSession(
        repository: StubDanmakuRepository
    ) -> (DanmakuSession, SessionTimeline, SessionPresentationSink) {
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        sink.catchUpWindowSeconds = Self.threeSegmentCatchUpWindowSeconds
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        return (session, timeline, sink)
    }

    /// 逐次发布 `position` 的快照并等呈现端收到，直到 repository 收到 `expected` 次请求。
    ///
    /// 会话只在处理时间线更新时发起请求；每步等的是产品事件，不按时长轮询。
    private func advanceUntilRequestCount(
        _ expected: Int,
        identity: PlaybackItemIdentity,
        generation: UInt64,
        position: Double = DanmakuSessionTests.threeSegmentPosition,
        timeline: SessionTimeline,
        sink: SessionPresentationSink,
        repository: StubDanmakuRepository
    ) async throws {
        while await repository.requestCount(for: identity) < expected {
            let nextUpdate = sink.updateCount(for: identity) + 1
            timeline.publish(
                snapshot(
                    identity: identity,
                    position: position,
                    generation: generation
                )
            )
            try await sink.waitForUpdateCount(nextUpdate, identity: identity)
        }
    }

    private func snapshot(
        identity: PlaybackItemIdentity,
        position: Double,
        generation: UInt64,
        rate: Double = 1,
        state: PlaybackTimelineState = .playing
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: identity,
            positionSeconds: position,
            durationSeconds: 1_800,
            rate: rate,
            state: state,
            discontinuityGeneration: generation
        )
    }
}

@MainActor
private final class SessionPresentationSink: DanmakuPresentationSink {
    var catchUpWindowSeconds = 0.0
    private(set) var updates: [DanmakuPresentationUpdate] = []
    private(set) var clearCount = 0
    private(set) var stopCount = 0
    private var updateWaiters:
        [UUID: (
            identity: PlaybackItemIdentity,
            count: Int,
            continuation: CheckedContinuation<Void, any Error>
        )] = [:]

    func apply(_ update: DanmakuPresentationUpdate) {
        updates.append(update)
        let ready = updateWaiters.filter {
            updateCount(for: $0.value.identity) >= $0.value.count
        }
        for (id, waiter) in ready where updateWaiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func setSpeedLevel(_ speedLevel: DanmakuSpeedLevel) {}
    func setOpacity(_ opacity: DanmakuOpacity) {}
    func setDisplayArea(_ displayArea: DanmakuDisplayArea) {}
    func setDensity(_ density: DanmakuDensity) {}

    func clearPresentation() {
        clearCount += 1
    }

    func stopPresentation() {
        stopCount += 1
    }

    func waitForUpdateCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if updateCount(for: identity) >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    updateWaiters[id] = (identity, expectedCount, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelUpdateWaiter(id)
            }
        }
    }

    private func cancelUpdateWaiter(_ id: UUID) {
        updateWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    func updateCount(for identity: PlaybackItemIdentity) -> Int {
        updates.lazy.filter { $0.snapshot.identity == identity }.count
    }
}

/// 记录认证失效回调；回调在 MainActor 上同步发生，次数可直接断言，也可等到达某个次数。
@MainActor
private final class InvalidationRecorder {
    private(set) var count = 0
    private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, any Error>)] =
        [:]

    func record() {
        count += 1
        let ready = waiters.filter { $0.value.count <= count }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (expectedCount, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}

@MainActor
private final class SessionTimeline: PlaybackTimelineProviding {
    private var snapshot = PlaybackTimelineSnapshot.idle
    private var continuations: [UUID: AsyncStream<PlaybackTimelineSnapshot>.Continuation] = [:]
    private var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]
    private var subscriberCountWaiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var currentTimelineSnapshot: PlaybackTimelineSnapshot { snapshot }

    func timelineUpdates() -> AsyncStream<PlaybackTimelineSnapshot> {
        let id = UUID()
        let stream = AsyncStream<PlaybackTimelineSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[id] = stream.continuation
        stream.continuation.yield(snapshot)
        stream.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                self?.removeContinuation(id)
            }
        }
        return stream.stream
    }

    func observeTimeline(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return { [weak self] in self?.observers[id] = nil }
    }

    func publish(_ snapshot: PlaybackTimelineSnapshot) {
        self.snapshot = snapshot
        for observer in Array(observers.values) {
            observer(snapshot)
        }
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func waitForSubscriberCount(_ count: Int) async {
        guard continuations.count != count else { return }
        await withCheckedContinuation { continuation in
            subscriberCountWaiters.append((count, continuation))
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
        let ready = subscriberCountWaiters.filter {
            continuations.count == $0.count
        }
        subscriberCountWaiters.removeAll {
            continuations.count == $0.count
        }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

/// 本 target 唯一的 `DanmakuSegmentRepository` 替身；按 behavior 立即成功、失败、每段首次失败
/// 或挂起到测试显式释放，并按 identity 记录请求与并发峰值。
private actor StubDanmakuRepository: DanmakuSegmentRepository {
    enum Behavior: Sendable {
        case succeed
        case fail(DanmakuApplicationError)
        case failFirstAttemptPerSegment(DanmakuApplicationError)
        case holdUntilReleased
    }

    private struct Request: Hashable {
        let identity: PlaybackItemIdentity
        let index: Int
    }

    private let behavior: Behavior
    private var requests: [Request] = []
    private var active = 0
    private var maximumActive = 0
    private var releasedIdentities: Set<PlaybackItemIdentity> = []
    private var releasesAll = false
    private var releaseWaiters: [PlaybackItemIdentity: [CheckedContinuation<Void, Never>]] = [:]
    private var requestEvents: [PlaybackItemIdentity: TestEventCounter] = [:]
    private var cancellationEvents: [PlaybackItemIdentity: TestEventCounter] = [:]

    init(_ behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func segment(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> DanmakuSegment {
        let request = Request(identity: identity, index: index)
        let isFirstAttempt = !requests.contains(request)
        requests.append(request)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        await counter(for: identity, in: &requestEvents).signal()

        switch behavior {
        case .succeed:
            break
        case .fail(let error):
            throw error
        case .failFirstAttemptPerSegment(let error):
            if isFirstAttempt { throw error }
        case .holdUntilReleased:
            // 挂起期间忽略取消以模拟迟到结果，但记录取消事件供测试确认旧会话已取消加载。
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if releasesAll || releasedIdentities.contains(identity) {
                        continuation.resume()
                    } else {
                        releaseWaiters[identity, default: []].append(continuation)
                    }
                }
            } onCancel: {
                Task { await self.recordCancellation(identity) }
            }
        }
        return DanmakuSegment(index: index, events: [])
    }

    func requestedIndices(for identity: PlaybackItemIdentity) -> [Int] {
        requests.filter { $0.identity == identity }.map(\.index)
    }

    func requestCount(for identity: PlaybackItemIdentity) -> Int {
        requests.lazy.filter { $0.identity == identity }.count
    }

    func maximumActiveRequests() -> Int { maximumActive }

    func waitForRequestCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        do {
            try await counter(for: identity, in: &requestEvents).wait(until: expectedCount)
        } catch {
            releaseAll()
            throw error
        }
    }

    func waitForCancellationCount(
        _ expectedCount: Int,
        identity: PlaybackItemIdentity
    ) async throws {
        do {
            try await counter(for: identity, in: &cancellationEvents).wait(until: expectedCount)
        } catch {
            releaseAll()
            throw error
        }
    }

    func release(_ identity: PlaybackItemIdentity) {
        releasedIdentities.insert(identity)
        for waiter in releaseWaiters.removeValue(forKey: identity) ?? [] {
            waiter.resume()
        }
    }

    func releaseAll() {
        releasesAll = true
        let pending = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }

    private func recordCancellation(_ identity: PlaybackItemIdentity) async {
        await counter(for: identity, in: &cancellationEvents).signal()
    }

    private func counter(
        for identity: PlaybackItemIdentity,
        in events: inout [PlaybackItemIdentity: TestEventCounter]
    ) -> TestEventCounter {
        if let counter = events[identity] {
            return counter
        }
        let counter = TestEventCounter()
        events[identity] = counter
        return counter
    }
}

private actor TestEventCounter {
    private struct Waiter {
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func signal() {
        count += 1
        let ready = waiters.filter { count >= $0.value.expectedCount }
        for (id, waiter) in ready where waiters.removeValue(forKey: id) != nil {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count >= expectedCount {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = Waiter(
                        expectedCount: expectedCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id)
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }
}
