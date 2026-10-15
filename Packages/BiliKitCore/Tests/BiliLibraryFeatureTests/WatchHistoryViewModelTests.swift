import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

@Suite(.timeLimit(.minutes(1)))
struct WatchHistoryViewModelTests {
    @Test
    @MainActor
    func loadsAndPaginatesWithoutDuplicatingBVIDs() async throws {
        let continuation = token(100)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: continuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1"), item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(model.successfulReloadGeneration == 1)
        let firstTailIdentity = model.paginationTailIdentity
        #expect(!model.isBusy)
        model.loadMore()
        #expect(model.isBusy)
        await model.waitForCurrentTask()
        #expect(!model.isBusy)
        #expect(model.successfulReloadGeneration == 1)

        guard case .loaded(let items, let nextContinuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(nextContinuation == nil)
        #expect(error == nil)
        #expect(firstTailIdentity != nil)
        #expect(model.paginationTailIdentity == nil)
        #expect(await repository.observedContinuations() == [nil, continuation])
    }

    /// 历史与首页推荐、热门、搜索共用上限：达到后收起分页尾标，也不再请求下一页。
    @Test
    @MainActor
    func stopsPaginatingAtTheSharedCapacity() async {
        let pageSize = 600
        let page: @Sendable (Int, WatchHistoryContinuation) -> WatchHistoryPage = { index, next in
            WatchHistoryPage(
                items: (index * pageSize..<(index + 1) * pageSize).map { item("BV-history-\($0)") },
                continuation: next
            )
        }
        let repository = HistoryRepositoryStub(
            results: [.success(page(0, token(1))), .success(page(1, token(2)))]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.paginationTailIdentity != nil)
        model.loadMore()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史达到上限后应保持 loaded")
            return
        }
        #expect(items.count == VideoListRetention.maximumItemCount)
        #expect(continuation == nil)
        #expect(error == nil)
        #expect(model.paginationTailIdentity == nil)
        #expect(!model.requiresManualLoadMore)
        #expect(await repository.observedContinuations() == [nil, token(1)])
    }

    /// continuation 回环是接口异常：恰好同时达到条目上限也要报告，不被上限吞掉。
    @Test
    @MainActor
    func continuationLoopAtCapacityStillReportsInvalidResponse() async {
        func page(_ range: Range<Int>, _ next: WatchHistoryContinuation) -> WatchHistoryPage {
            WatchHistoryPage(items: range.map { item("BV-loop-\($0)") }, continuation: next)
        }
        let repository = HistoryRepositoryStub(
            results: [
                .success(page(0..<300, token(1))),
                .success(page(300..<600, token(2))),
                .success(page(600..<1_000, token(1)))
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("回环后历史状态不是 loaded")
            return
        }
        #expect(items.count == VideoListRetention.maximumItemCount)
        #expect(continuation == nil)
        #expect(error == .invalidResponse)
    }

    @Test
    @MainActor
    func authenticationFailureRequestsRevalidation() async {
        let repository = HistoryRepositoryStub(
            results: [.failure(WatchHistoryError.authenticationRequired)]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.authenticationRequired))
        #expect(model.requiresAuthentication)
        #expect(model.successfulReloadGeneration == 0)
    }

    @Test
    @MainActor
    func requestDroppedBySessionChangeLeavesRetryableState() async {
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                // API 在认证会话切换时丢弃在途请求：抛出取消，但调用方任务本身没有被取消。
                repository: HistoryRepositoryStub(results: [.failure(CancellationError())])
            )
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.transportFailure))
        #expect(!model.isBusy)
    }

    @Test
    @MainActor
    func authenticationRevalidationFailureLeavesRetryableHistoryState() {
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: HistoryRepositoryStub(results: [])
            )
        )

        model.reportAuthenticationRevalidationFailure()

        #expect(model.state == .failed(.transportFailure))
        #expect(!model.isBusy)
    }

    @Test
    @MainActor
    func loadMoreFailureKeepsExistingItemsAndTailAvailableForRetry() async {
        let continuation = token(100)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: continuation
                    )
                ),
                .failure(WatchHistoryError.transportFailure)
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        let tailIdentity = model.paginationTailIdentity
        model.loadMore()

        #expect(
            model.state
                == .loadingMore(
                    items: [item("BV1HistoryA1")],
                    continuation: continuation
                )
        )
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: continuation,
                    loadMoreError: .transportFailure
                )
        )
        #expect(model.paginationTailIdentity == tailIdentity)
        #expect(!model.isBusy)
    }

    @Test
    @MainActor
    func emptyPaginationPageRequiresExplicitContinueAndThenRearms() async {
        let first = token(100)
        let second = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: first
                    )
                )
            ] + emptyPagesEnding(at: second) + [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: second,
                    loadMoreError: nil
                )
        )
        #expect(model.requiresManualLoadMore)
        #expect(model.paginationTailIdentity == nil)

        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, _) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(continuation == nil)
        #expect(!model.requiresManualLoadMore)
    }

    @Test
    @MainActor
    func manualPaginationFailureKeepsExplicitRetryAndCanRecover() async {
        let first = token(100)
        let manual = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: first
                    )
                )
            ] + emptyPagesEnding(at: manual) + [
                .failure(WatchHistoryError.transportFailure),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)

        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)
        #expect(
            model.state
                == .loaded(
                    items: [item("BV1HistoryA1")],
                    continuation: manual,
                    loadMoreError: .transportFailure
                )
        )

        model.loadMore()
        await model.waitForCurrentTask()
        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2"])
        #expect(continuation == nil)
        #expect(error == nil)
    }

    @Test
    @MainActor
    func repeatedOpaqueContinuationCycleStopsAutomaticPagination() async {
        let first = token(100)
        let second = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: first
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryB2")],
                        continuation: second
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryC3")],
                        continuation: first
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1", "BV1HistoryB2", "BV1HistoryC3"])
        #expect(continuation == nil)
        #expect(error == .invalidResponse)
        #expect(model.paginationTailIdentity == nil)
        #expect(!model.requiresManualLoadMore)
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func reloadPreventsOlderResultFromOverwritingNewIntent() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        try await repository.waitUntilCallCount(1)
        model.reload()
        try await repository.waitUntilCancellationCount(1)
        await model.waitForCurrentTask()
        await repository.releaseCall(1)

        guard case .loaded(let items, _, _) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryB2"])
        #expect(model.successfulReloadGeneration == 1)
    }

    /// 已有条目时刷新原地进行：刷新期间条目保持显示且不分页，成功后整体替换并推进刷新代次。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func refreshKeepsItemsVisibleUntilTheNewPageArrives() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        try await repository.waitUntilCallCount(2)
        let duringRefresh = model.state
        let wasRefreshing = model.isRefreshing
        let wasBusy = model.isBusy
        model.loadMore()
        let tailDuringRefresh = model.paginationTailIdentity
        await repository.releaseCall(2)
        await model.waitForCurrentTask()

        #expect(wasRefreshing)
        #expect(wasBusy)
        #expect(tailDuringRefresh == nil)
        guard case .loaded(let oldItems, _, _) = duringRefresh else {
            Issue.record("刷新期间历史状态不是 loaded")
            return
        }
        #expect(oldItems.map(\.bvid) == ["BV1HistoryA1"])
        guard case .loaded(let newItems, _, _) = model.state else {
            Issue.record("刷新后历史状态不是 loaded")
            return
        }
        #expect(newItems.map(\.bvid) == ["BV1HistoryB2"])
        #expect(!model.isRefreshing)
        #expect(model.refreshError == nil)
        #expect(model.successfulReloadGeneration == 2)
        #expect(await repository.observedContinuations() == [nil, nil])
    }

    /// 原地刷新失败保留已显示条目并恢复自动分页；登录失效仍进入终态，触发登录提示。
    @Test(arguments: [
        (WatchHistoryError.transportFailure, true),
        (.authenticationRequired, false)
    ])
    @MainActor
    func refreshFailureKeepsItemsUnlessAuthenticationExpired(
        failure: WatchHistoryError,
        keepsItems: Bool
    ) async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .failure(failure)
            ]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        await model.waitForCurrentTask()

        #expect(!model.isRefreshing)
        if keepsItems {
            guard case .loaded(let items, let continuation, nil) = model.state else {
                Issue.record("刷新失败后历史状态不是 loaded")
                return
            }
            #expect(items.map(\.bvid) == ["BV1HistoryA1"])
            #expect(continuation == token(1))
            #expect(model.refreshError == failure)
            #expect(model.paginationTailIdentity != nil)
            #expect(model.successfulReloadGeneration == 1)
        } else {
            #expect(model.state == .failed(failure))
            #expect(model.requiresAuthentication)
        }
    }

    /// 需要用户显式继续的分页状态在刷新失败后原样保留，不会变成自动连续扫描。
    @Test
    @MainActor
    func failedRefreshKeepsTheManualContinueGate() async {
        let manual = token(904)
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1)))
            ] + emptyPagesEnding(at: manual) + [.failure(WatchHistoryError.transportFailure)]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()
        #expect(model.requiresManualLoadMore)

        model.reload()
        await model.waitForCurrentTask()

        #expect(model.refreshError == .transportFailure)
        #expect(model.requiresManualLoadMore)
        #expect(model.paginationTailIdentity == nil)
        guard case .loaded(_, let continuation, _) = model.state else {
            Issue.record("刷新失败后历史状态不是 loaded")
            return
        }
        #expect(continuation == manual)
    }

    /// 离开页面会取消原地刷新，保留条目、恢复刷新前的分页状态，并清掉刷新错误。
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func leavingDuringRefreshKeepsItems() async throws {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .success(WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil))
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.reload()
        await model.waitForCurrentTask()

        model.reload()
        try await repository.waitUntilCallCount(2)
        model.deactivateRoute()
        await repository.releaseCall(2)
        await model.waitForCurrentTask()

        #expect(!model.isRefreshing)
        guard case .loaded(let items, _, _) = model.state else {
            Issue.record("离开后历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1HistoryA1"])
        #expect(model.paginationTailIdentity != nil)
        #expect(model.successfulReloadGeneration == 1)
    }

    @Test
    @MainActor
    func resetClearsPersonalizedItemsFromMemory() async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1HistoryA1")],
                        continuation: nil
                    )
                )
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.reset()

        #expect(model.state == .idle)
    }

    @Test
    @MainActor
    func resetRejectsLatePaginationContinuationMutation() async throws {
        let oldContinuation = token(100)
        let intermediateContinuation = token(200)
        let repository = HistoryRepositoryStub(
            results: [
                .success(
                    WatchHistoryPage(
                        items: [item("BV1OldA")],
                        continuation: oldContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1OldB")],
                        continuation: intermediateContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1NewA")],
                        continuation: intermediateContinuation
                    )
                ),
                .success(
                    WatchHistoryPage(
                        items: [item("BV1NewB")],
                        continuation: oldContinuation
                    )
                )
            ],
            suspendedCalls: [2]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.reload()
        await model.waitForCurrentTask()
        model.loadMore()
        try await repository.waitUntilCallCount(2)
        model.reset()
        try await repository.waitUntilCancellationCount(1)
        model.reload()
        await model.waitForCurrentTask()
        await repository.releaseCall(2)
        model.loadMore()
        await model.waitForCurrentTask()

        guard case .loaded(let items, let continuation, let error) = model.state else {
            Issue.record("历史状态不是 loaded")
            return
        }
        #expect(items.map(\.bvid) == ["BV1NewA", "BV1NewB"])
        #expect(continuation == oldContinuation)
        #expect(error == nil)
    }

    enum Interruption: CaseIterable, Sendable {
        case resetInitialLoad
        case deactivateInitialLoad
        case deactivatePagination
        case deactivateManualPagination
    }

    @Test(arguments: Interruption.allCases)
    @MainActor
    func interruptionCancelsInFlightLoadAndRejectsItsLateResult(
        _ interruption: Interruption
    ) async throws {
        let first = token(100)
        let manual = token(200)
        let firstPage: Result<WatchHistoryPage, any Error> = .success(
            WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: first)
        )
        let prefix: [Result<WatchHistoryPage, any Error>] =
            switch interruption {
            case .resetInitialLoad, .deactivateInitialLoad: []
            case .deactivatePagination: [firstPage]
            case .deactivateManualPagination: [firstPage] + emptyPagesEnding(at: manual)
            }
        let lateResult: Result<WatchHistoryPage, any Error> = .success(
            WatchHistoryPage(items: [item("BV1HistoryB2")], continuation: nil)
        )
        let repository = HistoryRepositoryStub(
            results: prefix + [lateResult],
            suspendedCalls: [prefix.count + 1]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        if !prefix.isEmpty {
            await model.waitForCurrentTask()
            if interruption == .deactivateManualPagination {
                model.loadMore()
                await model.waitForCurrentTask()
                #expect(model.requiresManualLoadMore)
            }
            model.loadMore()
        }
        try await repository.waitUntilCallCount(prefix.count + 1)
        if interruption == .resetInitialLoad {
            model.reset()
        } else {
            model.deactivateRoute()
        }
        try await repository.waitUntilCancellationCount(1)
        await repository.releaseCall(prefix.count + 1)

        switch interruption {
        case .resetInitialLoad, .deactivateInitialLoad:
            #expect(model.state == .idle)
        case .deactivatePagination:
            #expect(
                model.state
                    == .loaded(
                        items: [item("BV1HistoryA1")],
                        continuation: first,
                        loadMoreError: nil
                    )
            )
            #expect(!model.requiresManualLoadMore)
        case .deactivateManualPagination:
            #expect(
                model.state
                    == .loaded(
                        items: [item("BV1HistoryA1")],
                        continuation: manual,
                        loadMoreError: nil
                    )
            )
            #expect(model.requiresManualLoadMore)
            #expect(model.paginationTailIdentity == nil)
        }
    }
}

private func token(_ value: Int) -> WatchHistoryContinuation {
    WatchHistoryContinuation(rawValue: "fixture-\(value)")
}

/// UseCase 跳过 3 个空页后把第 4 个空页的 continuation 交给用户显式继续。
private func emptyPagesEnding(
    at manual: WatchHistoryContinuation
) -> [Result<WatchHistoryPage, any Error>] {
    [token(901), token(902), token(903), manual].map {
        .success(WatchHistoryPage(items: [], continuation: $0))
    }
}

private func item(_ bvid: String) -> WatchHistoryItem {
    WatchHistoryItem(
        bvid: bvid,
        title: "手写历史条目",
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "测试作者"),
        progressSeconds: 10,
        durationSeconds: 100,
        viewedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private actor HistoryRepositoryStub: WatchHistoryRepository {
    private var results: [Result<WatchHistoryPage, any Error>]
    private let suspendedCalls: Set<Int>
    private var callCount = 0
    private var continuations: [WatchHistoryContinuation?] = []
    private let callEvents = TestEventCounter()
    private let cancellationEvents = TestEventCounter()
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releasedCalls: Set<Int> = []

    init(
        results: [Result<WatchHistoryPage, any Error>],
        suspendedCalls: Set<Int> = []
    ) {
        self.results = results
        self.suspendedCalls = suspendedCalls
    }

    func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        callCount += 1
        let currentCall = callCount
        continuations.append(continuation)
        await callEvents.signal()
        guard !results.isEmpty else { throw WatchHistoryError.invalidResponse }
        let result = results.removeFirst()
        if suspendedCalls.contains(currentCall), !releasedCalls.contains(currentCall) {
            // 挂起期间忽略取消以模拟迟到结果，但记录取消事件供测试确认旧请求已被取消。
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    releaseWaiters[currentCall, default: []].append($0)
                }
            } onCancel: {
                Task { await self.cancellationEvents.signal() }
            }
        }
        return try result.get()
    }

    func observedContinuations() -> [WatchHistoryContinuation?] {
        continuations
    }

    func waitUntilCallCount(_ expectedCount: Int) async throws {
        do {
            try await callEvents.wait(until: expectedCount)
        } catch {
            releaseAllCalls()
            throw error
        }
    }

    func waitUntilCancellationCount(_ expectedCount: Int) async throws {
        do {
            try await cancellationEvents.wait(until: expectedCount)
        } catch {
            releaseAllCalls()
            throw error
        }
    }

    func releaseCall(_ call: Int) {
        releasedCalls.insert(call)
        let pending = releaseWaiters.removeValue(forKey: call) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }

    private func releaseAllCalls() {
        releasedCalls.formUnion(suspendedCalls)
        let pending = releaseWaiters.values.flatMap { $0 }
        releaseWaiters.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.resume()
        }
    }
}
