import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 会话本身不可观察，测试只经产品出口判断：repository 收到的请求、presentation sink 收到的更新与
/// 认证失效回调。「失败已被会话记下」没有通用出口，需要确定同步时以认证失效回调为信号。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuSessionTests {
    @Test
    func sessionPrefetchesCurrentAndNextWithBoundedConcurrency() async throws {
        let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 1)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 2])
        #expect(await repository.maximumActiveRequests() == 2)

        // 分段返回后，同一位置的后续时间线更新只交给呈现端，不再重复请求。
        await repository.release(identity)
        timeline.publish(snapshot(identity: identity, position: 0.5, generation: 1))
        try await sink.waitForUpdateCount(2, identity: identity)
        #expect(await repository.requestCount(for: identity) == 2)
        session.stop()
    }

    /// 会话把呈现端给出的补位窗口交给调度：窗口跨进上一分段时先请求当前与上一分段，
    /// 没有窗口时请求当前与下一分段。
    @Test(arguments: [(10.0, [1, 2]), (0.0, [2, 3])])
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
        timeline.publish(snapshot(identity: identity, position: 365, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == expectedIndices)
        session.stop()
        await repository.releaseAll()
    }

    @Test
    func replacingIdentityCancelsOldLoadsAndStopEndsTheSession() async throws {
        let first = PlaybackItemIdentity(bvid: "BV1FirstFixture", cid: 1)
        let second = PlaybackItemIdentity(bvid: "BV1SecondFixture", cid: 2)
        let repository = StubDanmakuRepository(.holdUntilReleased)
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: first)
        session.start(for: second)
        try await repository.waitForCancellationCount(2, identity: first)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await repository.release(second)
        await repository.release(first)

        // 旧视频迟到的分段不打乱新视频：继续推进时两边都不重复请求。
        timeline.publish(snapshot(identity: second, position: 0.5, generation: 2))
        try await sink.waitForUpdateCount(2, identity: second)
        #expect(await repository.requestCount(for: first) == 2)
        #expect(await repository.requestCount(for: second) == 2)

        // stop 结束整个会话：退订时间线，之后的快照既不请求也不再交给呈现端。
        session.stop()
        await timeline.waitForSubscriberCount(0)
        timeline.publish(snapshot(identity: second, position: 1, generation: 2))
        #expect(await repository.requestCount(for: second) == 2)
        #expect(sink.updateCount(for: second) == 2)
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

    /// 失败的分段（含被风控拒绝的）在当前视频内不再请求；412 的一次延迟重试由 API 客户端负责，
    /// 会话不叠加。每次更新都等呈现端收到，期间失败结果有机会写回会话。
    @Test(arguments: [DanmakuApplicationError.unavailable, .requestRestricted])
    func failedSegmentsAreNotRetriedByEveryLaterTimelineUpdate(
        error: DanmakuApplicationError
    ) async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1FailingDanmakuFixture",
            cid: 4
        )
        let repository = StubDanmakuRepository(.fail(error))
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        let updateCount = 128

        session.start(for: identity)
        timeline.publish(
            snapshot(
                identity: identity,
                position: 0,
                generation: 1
            )
        )
        try await repository.waitForRequestCount(2, identity: identity)

        for ordinal in 2...updateCount {
            timeline.publish(
                snapshot(
                    identity: identity,
                    position: 0,
                    generation: 1
                )
            )
            try await sink.waitForUpdateCount(
                ordinal,
                identity: identity
            )
        }

        let attempts = await repository.requestCount(for: identity)
        #expect(attempts == 2)
    }

    @Test
    func authenticationInvalidationIsReportedOncePerSession() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1AuthDanmakuFixture",
            cid: 40
        )
        let repository = StubDanmakuRepository(.fail(.authenticationInvalid))
        let timeline = SessionTimeline()
        let sink = SessionPresentationSink()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline,
            presentationSink: sink
        )
        let invalidations = InvalidationRecorder()
        session.setAuthenticationInvalidationHandler {
            invalidations.record()
        }

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)
        await invalidations.wait(until: 1)

        // 同一会话里另一个分段也以认证失效失败；继续推进时间线，回调仍只有一次。
        timeline.publish(snapshot(identity: identity, position: 0.5, generation: 1))
        try await sink.waitForUpdateCount(2, identity: identity)
        #expect(invalidations.count == 1)

        session.stop()
        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 2))
        try await repository.waitForRequestCount(4, identity: identity)

        await invalidations.wait(until: 2)
    }

    /// 换视频时清空失败记录：先等认证失效回调确认第一个视频的失败已被记下，再换到第二个视频。
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
        let repository = StubDanmakuRepository(.fail(.authenticationInvalid))
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )
        let invalidations = InvalidationRecorder()
        session.setAuthenticationInvalidationHandler {
            invalidations.record()
        }

        session.start(for: first)
        timeline.publish(snapshot(identity: first, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: first)
        await invalidations.wait(until: 1)

        session.start(for: second)
        timeline.publish(snapshot(identity: second, position: 0, generation: 2))
        try await repository.waitForRequestCount(2, identity: second)
        await invalidations.wait(until: 2)

        #expect(await repository.requestCount(for: first) == 2)
        #expect(await repository.requestCount(for: second) == 2)
    }

    /// stop 后重新开始同一视频时，上一轮失败的分段重新请求；失败同步方式同上。
    @Test
    func restartingSessionAllowsFailedSegmentsToRecover() async throws {
        let identity = PlaybackItemIdentity(
            bvid: "BV1RecoveringDanmakuFixture",
            cid: 7
        )
        let repository = StubDanmakuRepository(
            .failFirstAttemptPerSegment(.authenticationInvalid)
        )
        let timeline = SessionTimeline()
        let session = DanmakuSession(
            useCase: DanmakuSegmentUseCase(repository: repository),
            timeline: timeline
        )
        let invalidations = InvalidationRecorder()
        session.setAuthenticationInvalidationHandler {
            invalidations.record()
        }

        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 1))
        try await repository.waitForRequestCount(2, identity: identity)
        await invalidations.wait(until: 1)

        session.stop()
        session.start(for: identity)
        timeline.publish(snapshot(identity: identity, position: 0, generation: 2))
        try await repository.waitForRequestCount(4, identity: identity)

        #expect(await repository.requestedIndices(for: identity).sorted() == [1, 1, 2, 2])
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
            durationSeconds: 900,
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
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { $0.count <= count }
        waiters.removeAll { $0.count <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func wait(until expectedCount: Int) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
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
