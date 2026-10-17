import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import Foundation
import Observation
import Testing

@testable import BiliKit

/// App 测试 target 共用的等待与记录替身；各测试文件不再各自复制。

/// 在一次性的 UserDefaults suite 中执行；前后都清空，测试之间、测试与真实偏好互不影响。
func withIsolatedDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suiteName = "BiliKitMacTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("无法创建隔离的 UserDefaults suite")
        return
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
}

/// 等待 AppKit 在后续 main actor 回合完成的布局或 diff 应用；只让出执行权，不按固定时长轮询。
@MainActor
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { return false }
        await Task.yield()
    }
    return true
}

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

/// 可等待的事件计数：记录端 `record()`，等待端挂起到计数达到目标为止。
actor TestEventCounter {
    private(set) var count = 0
    private var waiters = CountWaiters()

    func record() {
        count += 1
        waiters.resume(reaching: count)
    }

    func wait(untilCount target: Int = 1) async {
        await withCheckedContinuation { waiters.add($0, until: target, current: count) }
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

/// `AuthenticatedSessionInvalidating` 的唯一测试替身，只记录失效次数。
actor RecordingSessionInvalidator: AuthenticatedSessionInvalidating {
    private(set) var invalidationCount = 0

    func invalidateAuthenticatedSession() {
        invalidationCount += 1
    }
}

/// 卡片取图 port 的最小替身：从不命中缓存，加载也不返回图；给只需要传入 port、不验证取图的视图用。
struct NoImageCardLoader: NativeVideoImageLoading {
    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage? { nil }

    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage? { nil }
}

/// Feed port 的唯一测试替身：推荐不可用，热门与搜索恒为空页。
///
/// App 根视图会激活浏览页，这里给不验证 Feed 的测试一个不依赖网络的来源。
struct EmptyFeedRepository: FeedRepository {
    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage {
        throw ContentApplicationError.unavailable
    }

    func popular(page: Int, pageSize: Int) async throws -> PopularPage {
        PopularPage(videos: [], pageNumber: page, pageSize: pageSize)
    }

    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage {
        SearchPage(
            videos: [],
            pageNumber: request.page,
            pageSize: 20,
            totalResults: 0,
            totalPages: 0
        )
    }
}

/// 观看历史 port 的唯一测试替身：给了 `error` 时每次读取都失败，否则返回空页。
struct WatchHistoryRepositoryStub: WatchHistoryRepository {
    var error: ContentApplicationError?

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        if let error { throw error }
        return WatchHistoryPage(items: [], continuation: nil)
    }
}

/// 单个视频的手写详情、分 P 与播放地址；`FixtureVideoRepository` 按它回答。
struct VideoFixture: Sendable {
    let aid: Int64
    let bvid: String
    let page: VideoPage
    let title: String

    init(
        aid: Int64 = 700_000,
        bvid: String = "BV1LifecycleFixture",
        cid: Int64 = 900_001,
        title: String = "生命周期测试视频"
    ) {
        self.aid = aid
        self.bvid = bvid
        page = VideoPage(
            cid: cid,
            index: 1,
            title: "P1",
            durationSeconds: 120
        )
        self.title = title
    }

    var identity: PlaybackItemIdentity {
        PlaybackItemIdentity(bvid: bvid, cid: page.cid)
    }

    var detail: VideoDetail {
        VideoDetail(
            bvid: bvid,
            title: title,
            summary: "手写测试数据",
            coverURL: nil,
            owner: VideoOwner(id: 10_001, name: "测试 UP 主"),
            statistics: VideoStatistics(
                viewCount: 10,
                danmakuCount: 2,
                likeCount: 3
            ),
            durationSeconds: 120,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            aid: aid,
            pages: [page]
        )
    }

    var playback: VideoPlayback {
        VideoPlayback(
            manifest: PlaybackManifest(
                videoRepresentations: [],
                originalAudioRepresentations: []
            ),
            mediaHeaders: [:]
        )
    }
}

/// 视频 port 的唯一测试替身：按 BVID 选择 fixture 回答详情与播放；`playbackError` 让每次播放请求都失败。
struct FixtureVideoRepository: VideoRepository {
    private let fixturesByBVID: [String: VideoFixture]
    private let playbackError: ContentApplicationError?

    init(
        fixtures: [VideoFixture],
        playbackError: ContentApplicationError? = nil
    ) {
        fixturesByBVID = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.bvid, $0) })
        self.playbackError = playbackError
    }

    func videoDetail(for bvid: String) async throws -> VideoDetail {
        try fixture(bvid).detail
    }

    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback {
        if let playbackError { throw playbackError }
        return try fixture(bvid).playback
    }

    private func fixture(_ bvid: String) throws -> VideoFixture {
        guard let fixture = fixturesByBVID[bvid] else {
            throw ContentApplicationError.invalidRequest
        }
        return fixture
    }
}

/// UP 主名片 port 的唯一测试替身：请求挂起到 `releaseLateResult()` 为止，用于验证迟到结果与取消。
actor PendingUploaderProfileRepository:
    UploaderProfileRepository
{
    private var requestStarted = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<UploaderProfile, Never>?
    private var requestCompleted = false
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        requestStarted = true
        requestWaiters.resumeAll()
        let result = await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
        requestCompleted = true
        completionWaiters.resumeAll()
        return result
    }

    func waitForRequest() async throws {
        guard !requestStarted else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append(continuation)
        }
    }

    func releaseLateResult() {
        resultContinuation?.resume(returning: UploaderProfile(signature: "迟到签名", isVIP: true))
        resultContinuation = nil
    }

    func waitForCompletion() async throws {
        guard !requestCompleted else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }
}

/// 播放 port 的唯一测试替身：记录 load/begin/stop；`holdsLoads` 时 load 挂起到
/// `failPendingLoad()` 为止，用于驱动加载失败路径。
@MainActor
final class RecordingPlayback: PlaybackControlling {
    private struct ControlledFailure: Error {}

    private let holdsLoads: Bool
    private(set) var loadedIdentities: [PlaybackItemIdentity] = []
    private(set) var startedIdentities: [PlaybackItemIdentity] = []
    private(set) var stopCallCount = 0
    private var pendingLoad: CheckedContinuation<Void, any Error>?
    private var loadWaiters = CountWaiters()
    private var stopWaiters = CountWaiters()

    init(holdsLoads: Bool = false) {
        self.holdsLoads = holdsLoads
    }

    func playbackFailureEvents() -> AsyncStream<PlaybackFailureEvent> {
        AsyncStream { $0.finish() }
    }

    func load(
        _ playback: VideoPlayback,
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        startPositionSeconds: Double?
    ) async throws {
        loadedIdentities.append(identity)
        loadWaiters.resume(reaching: loadedIdentities.count)
        guard holdsLoads else { return }
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
        }
    }

    func beginPlayback(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent
    ) async -> PlaybackStartOutcome {
        startedIdentities.append(identity)
        return .startedAtBeginning
    }

    func restartFromBeginning(
        identity: PlaybackItemIdentity,
        intent: PlaybackLoadIntent,
        resumeToken: PlaybackResumeToken
    ) async -> Bool { false }

    func pause() {}

    func stop() {
        stopCallCount += 1
        stopWaiters.resume(reaching: stopCallCount)
    }

    func failPendingLoad() {
        pendingLoad?.resume(throwing: ControlledFailure())
        pendingLoad = nil
    }

    func waitForLoadCallCount(_ target: Int) async {
        await withCheckedContinuation {
            loadWaiters.add($0, until: target, current: loadedIdentities.count)
        }
    }

    func waitForStopCallCount(_ target: Int) async {
        await withCheckedContinuation {
            stopWaiters.add($0, until: target, current: stopCallCount)
        }
    }
}

/// UP 主空间投稿 port 的唯一测试替身：每次读取都失败（不可用），只用于让空间层打开而不依赖网络。
struct UnavailableUploaderVideoRepository: UploaderVideoRepository {
    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        throw ContentApplicationError.unavailable
    }
}

/// 侧栏上下文层（UP 主空间）的真实模型；投稿读取恒失败，名片请求挂起到测试放行。
@MainActor
func makeUploaderSpace(
    profiles: PendingUploaderProfileRepository = PendingUploaderProfileRepository()
) -> UploaderSpaceViewModel {
    UploaderSpaceViewModel(
        useCase: UploaderVideoUseCase(repository: UnavailableUploaderVideoRepository()),
        profileUseCase: UploaderProfileUseCase(repository: profiles)
    )
}
