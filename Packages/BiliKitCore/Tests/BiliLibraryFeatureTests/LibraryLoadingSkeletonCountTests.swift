import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 资料库列表加载骨架的本页条数只来自同一条件上次成功加载的总数，封顶为一页；首次进入、条件变化与 `reset` 后
/// 不知道，观看历史没有总数、始终不知道。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct LibraryLoadingSkeletonCountTests {
    @Test
    func sameConditionReloadUsesTheLastTotalCappedToOnePage() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: 2, total: 35),
                .failure(ContentApplicationError.authenticationInvalid),
                laterPage(["BV1LaterA1"], page: 1, next: nil, total: 3),
                .failure(ContentApplicationError.authenticationInvalid),
                laterPage(["BV1LaterA1"], page: 1, next: nil, total: 3)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))

        model.loadIfNeeded()
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == nil)
        await model.waitForCurrentTask()

        // 凭据失败放弃条目，再次加载是同一条件下的清空重载：35 条封顶为一页。
        model.reload()
        await model.waitForCurrentTask()
        model.reload()
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == WatchLaterUseCase.pageSize)
        await model.waitForCurrentTask()

        // 总数不足一页时按总数。
        model.reload()
        await model.waitForCurrentTask()
        model.reload()
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == 3)
        await model.waitForCurrentTask()
    }

    @Test
    func conditionChangeAndResetForgetTheTotal() async {
        let repository = WatchLaterRepositoryStub(
            results: [
                laterPage(["BV1LaterA1"], page: 1, next: nil, total: 3),
                laterPage(["BV1LaterB2"], page: 1, next: nil, total: 4),
                laterPage(["BV1LaterB2"], page: 1, next: nil, total: 4)
            ]
        )
        let model = WatchLaterViewModel(useCase: WatchLaterUseCase(repository: repository))
        let session = WatchLaterSession(model: model)
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        session.filterSelection.order = .oldestAdded
        session.selectOrder(.oldestAdded)
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == nil)
        await model.waitForCurrentTask()

        model.reset()
        #expect(model.expectedLoadingItemCount == nil)
        model.loadIfNeeded()
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == nil)
        await model.waitForCurrentTask()
    }

    @Test
    func historyNeverKnowsThePageItemCount() async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)),
                .failure(ContentApplicationError.authenticationInvalid),
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil))
            ]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))

        model.loadIfNeeded()
        #expect(model.expectedLoadingItemCount == nil)
        await model.waitForCurrentTask()
        model.reload()
        await model.waitForCurrentTask()
        model.reload()
        #expect(model.state == .loading)
        #expect(model.expectedLoadingItemCount == nil)
        await model.waitForCurrentTask()
    }
}
