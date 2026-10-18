import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看会话：排序、应用筛选、提交或清空关键词都以新条件的第一页从空列表重新加载，旧条件的在途结果不并入；
/// 弹窗草稿未应用不发请求；有筛选或关键词时界面可给出“清除筛选”；`reset` 与账户变化把条件恢复为默认。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterSessionTests {
    @Test
    @MainActor
    func criteriaChangeReloadsFromScratchAndDropsTheOldInFlightResult() async throws {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: nil, total: 1),
                laterPage(["BV1New"], page: 1, next: nil, total: 7)
            ],
            suspendedCalls: [1]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)

        model.loadIfNeeded()
        try await repository.waitUntilCallCount(1)
        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        #expect(model.state == .loading)
        await model.waitForCurrentTask()
        await repository.releaseCall(1)

        #expect(
            model.state
                == .loaded(items: [laterItem("BV1New")], continuation: nil, loadMoreError: nil)
        )
        #expect(model.totalCount == 7)
        #expect(model.successfulReloadGeneration == 1)
        let requests = await repository.requests
        #expect(requests.map(\.criteria.order) == [.newestAdded, .oldestAdded])
    }

    /// 已显示条目时换条件也不原地刷新：旧条件的条目立即撤下，进入加载。
    @Test
    @MainActor
    func criteriaChangeDoesNotKeepTheOldItemsOnScreen() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: 2, total: 30),
                laterPage(["BV1New"], page: 1, next: nil, total: 1)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.searchDraft = "猫"
        #expect(await repository.requests.count == 1)
        session.submitSearch()

        #expect(model.state == .loading)
        #expect(model.totalCount == nil)
        await model.waitForCurrentTask()
        #expect(session.narrowsResults)
        #expect(
            await repository.requests.last
                == WatchLaterRequest(criteria: WatchLaterCriteria(keyword: "猫"))
        )
    }

    /// 下一页沿用当前条件。
    @Test
    @MainActor
    func nextPageKeepsTheAppliedCriteria() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1Old"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: 2),
                laterPage(["BV1B"], page: 2, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        var selection = session.filterSelection
        selection.progress = .unfinished
        selection.duration = .overSixtyMinutes

        session.applyFilters(selection)
        await model.waitForCurrentTask()
        model.loadMore()
        await model.waitForCurrentTask()

        let expected = WatchLaterCriteria(progress: .unfinished, duration: .overSixtyMinutes)
        #expect(
            await repository.requests == [
                WatchLaterRequest(),
                WatchLaterRequest(criteria: expected, page: 1),
                WatchLaterRequest(criteria: expected, page: 2)
            ]
        )
    }

    /// 弹窗只编辑选择的草稿副本；没有“应用”时不发请求、已应用的条件不变。
    @Test
    @MainActor
    func editingTheSelectionWithoutApplyingSendsNothing() async {
        let repository = WatchLaterRepositoryStub(results: [laterPage(["BV1A"], page: 1, next: nil)]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.filterSelection.progress = .unfinished
        session.searchDraft = "未提交"

        #expect(session.appliedCriteria == WatchLaterCriteria())
        #expect(!session.narrowsResults)
        #expect(await repository.requests.count == 1)
    }

    /// 清空搜索框即恢复全部；清除筛选同时清掉关键词，保留排序。
    @Test
    @MainActor
    func clearingRestoresEverythingButTheOrder() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage([], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage([], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1A"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.searchDraft = "猫"
        session.submitSearch()
        await model.waitForCurrentTask()
        session.searchDraft = " "
        await model.waitForCurrentTask()
        #expect(session.appliedCriteria.keyword.isEmpty)

        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        await model.waitForCurrentTask()
        var selection = session.filterSelection
        selection.duration = .underTenMinutes
        session.applyFilters(selection)
        await model.waitForCurrentTask()
        #expect(session.narrowsResults)

        session.clearFilters()
        await model.waitForCurrentTask()

        #expect(session.appliedCriteria == WatchLaterCriteria(order: .oldestAdded))
        #expect(session.filterSelection.activeFilterCount == 0)
        #expect(session.searchDraft.isEmpty)
        #expect(!session.narrowsResults)
        #expect(await repository.requests.count == 6)
    }

    @Test
    @MainActor
    func resetAndAccountChangeRestoreTheDefaultCriteria() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1A"], page: 1, next: nil),
                laterPage(["BV1B"], page: 1, next: nil),
                laterPage(["BV1C"], page: 1, next: nil),
                laterPage(["BV1D"], page: 1, next: nil),
                laterPage(["BV1E"], page: 1, next: nil)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        session.searchDraft = "猫"
        session.submitSearch()
        await model.waitForCurrentTask()

        session.reset()
        #expect(model.state == .idle)
        #expect(session.appliedCriteria == WatchLaterCriteria())
        #expect(session.searchDraft.isEmpty)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        await model.waitForCurrentTask()
        session.synchronizeAuthenticationSession(
            scope: .signedIn(accountID: 2),
            isCurrentRoute: true
        )
        await model.waitForCurrentTask()

        #expect(session.filterSelection.order == .newestAdded)
        #expect(session.filterSelection.activeFilterCount == 0)
        let requests = await repository.requests
        #expect(
            requests.map(\.criteria) == [
                WatchLaterCriteria(),
                WatchLaterCriteria(keyword: "猫"),
                WatchLaterCriteria(),
                WatchLaterCriteria(order: .oldestAdded),
                WatchLaterCriteria()
            ]
        )
    }
}
