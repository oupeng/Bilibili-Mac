import BiliApplication
import BiliModels
import Foundation
import Observation

@testable import BiliVideoDetailFeature

/// 本 target 共用的等待、闸门与各 port 替身；各测试文件不再各自复制。

/// 等待 `@Observable` 状态满足条件：每次被追踪属性变化后才重新判断，超时由测试的 time limit 兜底。
@MainActor
func waitForObservedState(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}

/// 等到当前视频意图写回终态；内容准备与播放器安装期间的状态都不算完成。
@MainActor
func waitUntilSettled(_ model: VideoViewModel) async {
    await waitForObservedState {
        switch model.state {
        case .idle, .ready, .failed, .failedPage:
            true
        case .loading, .loadingPage, .preparingPlayback:
            false
        }
    }
}

/// 让替身中的请求挂起到测试放行；放行后后续请求直接通过。
///
/// 挂起期间忽略取消以模拟迟到结果，但记录取消事件，测试据此确认旧意图已被新意图取消。
///
/// 使用约定：请求进入后到 `open()` 之前，只用不会 throw 的断言或本闸门自己的等待（它们失败时先放行）；
/// 其他会 throw 的步骤放到 `open()` 之后，否则测试提前结束会让挂起的请求永不恢复。
actor TestGate {
    private let entries = TestEventCounter()
    private let cancellations = TestEventCounter()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        await entries.signal()
        guard !isOpen else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancellations.signal() }
        }
    }

    /// 等到第 `count` 个请求进入；等待失败时先放行，避免挂起的请求拖住测试。
    func waitForEntries(_ count: Int = 1) async throws {
        do {
            try await entries.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    /// 等到第 `count` 个挂起中的请求被取消；等待失败时先放行。
    func waitForCancellations(_ count: Int = 1) async throws {
        do {
            try await cancellations.wait(until: count)
        } catch {
            open()
            throw error
        }
    }

    func open() {
        isOpen = true
        waiters.resumeAll()
    }
}

actor TestEventCounter {
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

// MARK: - 挂起与计数等待

/// 由持有者在自己的隔离域内同步使用的计数等待表；计数本身由持有者保存与推进。
struct CountWaiters {
    private var pending: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// `current` 已达到 `target` 时立即恢复，否则登记到 `resume(reaching:)`。
    mutating func add(
        _ continuation: CheckedContinuation<Void, Never>,
        until target: Int,
        current: Int
    ) {
        if current >= target {
            continuation.resume()
        } else {
            pending.append((target, continuation))
        }
    }

    mutating func resume(reaching count: Int) {
        let ready = pending.filter { $0.target <= count }
        pending.removeAll { $0.target <= count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

extension Array where Element == CheckedContinuation<Void, Never> {
    /// 放行并清空全部挂起者。
    mutating func resumeAll() {
        let pending = self
        removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

// MARK: - 仓库替身

/// 由闭包回答的仓库请求；`attempt` 是同一请求第几次到达（从 1 开始），用于表达“首次失败、重试成功”。
typealias ScriptedResponse<Request, Value> =
    @Sendable (Request, _ attempt: Int) async throws -> Value

/// 本 target 唯一的 `VideoRepository` 替身：详情、分 P 与播放各由闭包回答，并按到达顺序记录请求。
///
/// 需要挂起时在闭包里经过 `TestGate`；需要失败时按 `attempt` 或放行后抛错。
actor VideoRepositoryStub: VideoRepository {
    private let detailResponse: ScriptedResponse<String, VideoDetail>
    private let pagesResponse: ScriptedResponse<String, [VideoPage]>
    private let playbackResponse: ScriptedResponse<PlaybackItemIdentity, VideoPlayback>
    private(set) var detailRequests: [String] = []
    private(set) var playbackRequests: [PlaybackItemIdentity] = []

    init(
        detail: @escaping ScriptedResponse<String, VideoDetail>,
        pages: @escaping ScriptedResponse<String, [VideoPage]>,
        playback: @escaping ScriptedResponse<PlaybackItemIdentity, VideoPlayback>
    ) {
        detailResponse = detail
        pagesResponse = pages
        playbackResponse = playback
    }

    /// `/view` 响应自带分 P：详情脚本给出其余字段，分 P 脚本给出 `pages`。
    func videoDetail(for bvid: String) async throws -> VideoDetail {
        detailRequests.append(bvid)
        let attempt = detailRequests.filter { $0 == bvid }.count
        let detail = try await detailResponse(bvid, attempt)
        return VideoDetail(
            bvid: detail.bvid,
            title: detail.title,
            summary: detail.summary,
            coverURL: detail.coverURL,
            owner: detail.owner,
            statistics: detail.statistics,
            durationSeconds: detail.durationSeconds,
            publishedAt: detail.publishedAt,
            dimension: detail.dimension,
            aid: detail.aid,
            pages: try await pagesResponse(bvid, attempt),
            collection: detail.collection,
            access: detail.access
        )
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        let identity = PlaybackItemIdentity(bvid: bvid, cid: cid)
        playbackRequests.append(identity)
        let attempt = playbackRequests.filter { $0 == identity }.count
        return try await playbackResponse(identity, attempt)
    }
}

extension VideoRepositoryStub {
    /// 所有请求都由同一个 fixture 回答；默认只有一个分 P。
    init(
        _ fixture: ContentFixtures,
        pages: [VideoPage]? = nil,
        playback: ScriptedResponse<PlaybackItemIdentity, VideoPlayback>? = nil
    ) {
        self.init(
            detail: { _, _ in fixture.detail },
            pages: { _, _ in pages ?? [fixture.page] },
            playback: playback ?? { _, _ in fixture.playback }
        )
    }

    /// 按 BVID 选择 fixture；未知 BVID 视为无效响应，`cancelledBVID` 的详情请求被取消。
    init(fixtures: [ContentFixtures], cancelledBVID: String? = nil) {
        let fixturesByBVID = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) }
        )
        let fixture: @Sendable (String) throws -> ContentFixtures = { bvid in
            guard let fixture = fixturesByBVID[bvid] else {
                throw ContentApplicationError.invalidResponse
            }
            return fixture
        }
        self.init(
            detail: { bvid, _ in
                if bvid == cancelledBVID { throw CancellationError() }
                return try fixture(bvid).detail
            },
            pages: { bvid, _ in [try fixture(bvid).page] },
            playback: { identity, _ in try fixture(identity.bvid).playback }
        )
    }
}

/// 单个视频的合成详情、分 P 与播放地址；`VideoRepositoryStub` 的便捷构造按它回答。
struct ContentFixtures: Sendable {
    let bvid: String
    let title: String
    let owner = VideoOwner(id: 10_001, name: "测试 UP 主")

    init(
        bvid: String = "BV1FixtureA1",
        title: String = "测试视频"
    ) {
        self.bvid = bvid
        self.title = title
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: title,
            summary: "脱敏详情",
            coverURL: nil,
            owner: owner,
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pages: [page]
        )
    }

    let page = VideoPage(
        cid: 900_001,
        index: 1,
        title: "P1",
        durationSeconds: 120
    )

    var twoPages: [VideoPage] {
        [page, VideoPage(cid: 900_002, index: 2, title: "P2", durationSeconds: 180)]
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [
                "Referer": "https://www.bilibili.com/video/\(bvid)/",
                "User-Agent": "BiliKitMacTests"
            ]
        )
    }

    func playback(resuming metadata: PlaybackResumeMetadata) -> VideoPlayback {
        VideoPlayback(
            media: playback.media,
            mediaHeaders: playback.mediaHeaders,
            resumeMetadata: metadata
        )
    }
}

/// 本 target 唯一的 UploaderProfileRepository 替身：`immediate` 为 nil 时每个请求挂起到测试按序号放行。
actor ProfileRepositoryStub: UploaderProfileRepository {
    private let immediate: Result<UploaderProfile, ContentApplicationError>?
    private var held: [CheckedContinuation<UploaderProfile, Never>?] = []
    private var requestWaiters = CountWaiters()
    private(set) var callCount = 0

    init(immediate: Result<UploaderProfile, ContentApplicationError>? = nil) {
        self.immediate = immediate
    }

    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        callCount += 1
        if let immediate { return try immediate.get() }
        return await withCheckedContinuation { continuation in
            held.append(continuation)
            requestWaiters.resume(reaching: held.count)
        }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: count, current: held.count)
        }
    }

    func releaseRequest(_ index: Int, profile: UploaderProfile) {
        held[index]?.resume(returning: profile)
        held[index] = nil
    }
}

/// RelatedVideoRepository 的唯一替身：按序消费 `responses`，用尽后挂起到测试按序号放行。
actor RelatedRepositoryStub: RelatedVideoRepository {
    private var responses: [Result<[RelatedVideo], ContentApplicationError>]
    private var held: [Int: CheckedContinuation<[RelatedVideo], Never>] = [:]
    private var requestWaiters = CountWaiters()
    private(set) var callCount = 0

    init(responses: [Result<[RelatedVideo], ContentApplicationError>] = []) {
        self.responses = responses
    }

    func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        callCount += 1
        let index = callCount - 1
        requestWaiters.resume(reaching: callCount)
        if !responses.isEmpty { return try responses.removeFirst().get() }
        return await withCheckedContinuation { held[index] = $0 }
    }

    func waitForRequestCount(_ count: Int) async {
        await withCheckedContinuation {
            requestWaiters.add($0, until: count, current: callCount)
        }
    }

    func releaseRequest(_ index: Int, videos: [RelatedVideo]) {
        held.removeValue(forKey: index)?.resume(returning: videos)
    }
}

extension RelatedVideo {
    static func testFixture(bvid: String) -> RelatedVideo {
        RelatedVideo(
            bvid: bvid,
            title: "合成相关推荐",
            coverURL: nil,
            ownerName: "测试作者",
            viewCount: 100,
            danmakuCount: 10,
            durationSeconds: 120
        )
    }
}

/// 唯一的 PlaybackControlling 替身，记录 load、开播、重播与停止。
///
/// 可让指定 BVID 的 load 失败、让第 `heldLoad` 次 load 挂起到测试放行，
/// 或让首个 load 先发布失败再等到 stop 才返回。失败事件与生产 engine 一样经 `AsyncBroadcast`
/// 发布：不回放、每个订阅独立，所以 ViewModel 必须在发起 load 前订阅；测试可等 ViewModel
/// 回来请求下一个事件。
@MainActor
final class PlayerStub: PlaybackControlling {
    private let startOutcome: PlaybackStartOutcome
    private let restartSucceeds: Bool
    private let holdsRestarts: Bool
    private let failingBVID: String?
    private let heldLoad: Int?
    private let failsFirstLoadUntilStopped: Bool
    private let failures = AsyncBroadcast<PlaybackFailureEvent>()
    private var failureRequestCount = 0
    private var failureRequestWaiters = CountWaiters()
    private var heldLoadContinuation: CheckedContinuation<Void, Never>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()
    private var restartWaiters = CountWaiters()
    private var heldRestarts: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var loadedPlaybacks: [VideoPlayback] = []
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var loadedIntents: [PlaybackLoadIntent] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIntents: [PlaybackLoadIntent] = []
    private(set) var loadedStartPositions: [Double?] = []
    private(set) var restartTokens: [PlaybackResumeToken] = []
    private(set) var stopCallCount = 0

    init(
        startOutcome: PlaybackStartOutcome = .startedAtBeginning,
        restartSucceeds: Bool = false,
        holdsRestarts: Bool = false,
        failingBVID: String? = nil,
        heldLoad: Int? = nil,
        failsFirstLoadUntilStopped: Bool = false
    ) {
        self.startOutcome = startOutcome
        self.restartSucceeds = restartSucceeds
        self.holdsRestarts = holdsRestarts
        self.failingBVID = failingBVID
        self.heldLoad = heldLoad
        self.failsFirstLoadUntilStopped = failsFirstLoadUntilStopped
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        let subscription = CountingFailureSubscription(
            failures.subscribe(startingWith: nil)
        ) { [weak self] in
            self?.recordFailureRequest()
        }
        return AsyncStream(unfolding: { await subscription.next() })
    }

    private func recordFailureRequest() {
        failureRequestCount += 1
        failureRequestWaiters.resume(reaching: failureRequestCount)
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        loadedPlaybacks.append(playback)
        loadedStartPositions.append(startPositionSeconds)
        loadedIdentities.append(identity)
        loadedIntents.append(intent)
        loadWaiters.resume(reaching: loadedIdentities.count)
        if identity.bvid == failingBVID {
            throw PlayerStubFailure()
        }
        if failsFirstLoadUntilStopped, loadedIdentities.count == 1 {
            failures.yield(PlaybackFailureEvent(identity: identity, intent: intent))
            await withCheckedContinuation { heldLoadContinuation = $0 }
        } else if loadedIdentities.count == heldLoad {
            await withCheckedContinuation { heldLoadContinuation = $0 }
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        startedIntents.append(intent)
        return startOutcome
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool {
        let index = restartTokens.count
        restartTokens.append(resumeToken)
        restartWaiters.resume(reaching: restartTokens.count)
        if holdsRestarts {
            await withCheckedContinuation { heldRestarts[index] = $0 }
        }
        return restartSucceeds
    }

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
        if failsFirstLoadUntilStopped {
            releaseHeldLoad()
        }
    }

    /// 以该 identity 最近一次 load 的 intent 发布 ready 后失败。
    func fail(_ identity: PlaybackItemIdentity) async {
        guard let index = loadedIdentities.lastIndex(of: identity) else { return }
        await publishFailure(PlaybackFailureEvent(identity: identity, intent: loadedIntents[index]))
    }

    func publishFailure(_ event: PlaybackFailureEvent) async {
        failures.yield(event)
    }

    func waitForFailureRequestCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            failureRequestWaiters.add($0, until: expectedCount, current: failureRequestCount)
        }
    }

    func waitForLoadCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: expectedCount, current: loadedIdentities.count)
        }
    }

    func releaseHeldLoad() {
        heldLoadContinuation?.resume()
        heldLoadContinuation = nil
    }

    func waitForRestartCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            restartWaiters.add($0, until: expectedCount, current: restartTokens.count)
        }
    }

    func releaseRestart(at index: Int) {
        heldRestarts.removeValue(forKey: index)?.resume()
    }

    func waitForStopCallCount(_ expectedCount: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: expectedCount, current: stopCallCount)
        }
    }
}

/// 一个失败事件订阅；每次取下一个事件前通知替身，测试据此确认 ViewModel 已处理完上一个事件。
@MainActor
private final class CountingFailureSubscription {
    private var iterator: AsyncStream<PlaybackFailureEvent>.Iterator
    private let onRequest: @MainActor () -> Void

    init(
        _ stream: AsyncStream<PlaybackFailureEvent>,
        onRequest: @escaping @MainActor () -> Void
    ) {
        iterator = stream.makeAsyncIterator()
        self.onRequest = onRequest
    }

    func next() async -> PlaybackFailureEvent? {
        onRequest()
        var iterator = self.iterator
        let event = await iterator.next(isolation: #isolation)
        self.iterator = iterator
        return event
    }
}

private struct PlayerStubFailure: Error {}
