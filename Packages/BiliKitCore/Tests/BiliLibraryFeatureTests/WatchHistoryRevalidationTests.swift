import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 观看历史的凭据失败与账户复核：何时请求复核、复核后何时自动重载、复核结束与离开页面时的状态。
@Suite(.timeLimit(.minutes(1)))
struct WatchHistoryRevalidationTests {
    /// 历史页只在已登录时显示：凭据失效与本地无凭据都说明窗口登录状态过期，请求复核。
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationRequired
    ])
    @MainActor
    func credentialFailureRequestsRevalidation(failure: ContentApplicationError) async {
        let repository = HistoryRepositoryStub(results: [.failure(failure)])
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(failure))
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.successfulReloadGeneration == 0)
    }

    /// Keychain 等本地凭据读不到：显示可重试的“无法读取登录状态”，不复核账户。
    @Test
    @MainActor
    func unavailableCredentialIsRetryableWithoutRevalidation() async {
        let repository = HistoryRepositoryStub(
            results: [.failure(ContentApplicationError.authenticationUnavailable)]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.authenticationUnavailable))
        #expect(ContentApplicationError.authenticationUnavailable.isRetryable)
        #expect(model.authenticationRevalidationGeneration == 0)
    }

    /// 复核确认仍已登录后自动重载一次；重载又得到凭据失效时只再请求一次复核，不再自动重载。
    @Test
    @MainActor
    func revalidationReloadsAtMostOncePerSession() async {
        let repository = HistoryRepositoryStub(
            results: [
                .failure(ContentApplicationError.authenticationInvalid),
                .failure(ContentApplicationError.authenticationInvalid)
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.resumeAfterAuthenticationRevalidation()
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 2)

        model.resumeAfterAuthenticationRevalidation()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(.authenticationInvalid))
        #expect(await repository.observedContinuations() == [nil, nil])
        #expect(model.authenticationRevalidationGeneration == 2)
        // 复核已结束：失败页不再显示“正在重新确认”。
        #expect(!model.isAwaitingAuthenticationRevalidation)
    }

    /// 加载更多遇到凭据失效与刷新一致：不再显示该账户的条目，转入失败页并请求复核。
    @Test(arguments: [
        ContentApplicationError.authenticationInvalid,
        .authenticationRequired
    ])
    @MainActor
    func loadMoreCredentialFailureClearsItems(failure: ContentApplicationError) async {
        let repository = HistoryRepositoryStub(
            results: [
                .success(WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: token(1))),
                .failure(failure)
            ]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        model.loadMore()
        await model.waitForCurrentTask()

        #expect(model.state == .failed(failure))
        #expect(model.paginationTailIdentity == nil)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.isAwaitingAuthenticationRevalidation)
    }

    /// 用户在复核结束前手动重试成功：不再等待复核，复核结束时不会多一次重载。
    @Test
    @MainActor
    func successfulLoadEndsTheWaitForRevalidation() async {
        let page = WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)
        let repository = HistoryRepositoryStub(
            results: [.failure(ContentApplicationError.authenticationInvalid), .success(page)]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.reload()
        await model.waitForCurrentTask()
        #expect(!model.isAwaitingAuthenticationRevalidation)

        model.resumeAfterAuthenticationRevalidation()
        await model.waitForCurrentTask()

        #expect(model.state == .loaded(items: page.items, continuation: nil, loadMoreError: nil))
        #expect(await repository.observedContinuations().count == 2)
    }

    /// 复核期间离开历史页：不再等待复核，凭据失败页回到 idle，回来时重新加载。
    @Test
    @MainActor
    func leavingDuringRevalidationReloadsOnReturn() async {
        let page = WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)
        let repository = HistoryRepositoryStub(
            results: [.failure(ContentApplicationError.authenticationInvalid), .success(page)]
        )
        let model = WatchHistoryViewModel(useCase: WatchHistoryUseCase(repository: repository))
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        model.deactivateRoute()
        #expect(model.state == .idle)
        #expect(!model.isAwaitingAuthenticationRevalidation)

        model.loadIfNeeded()
        await model.waitForCurrentTask()
        #expect(model.state == .loaded(items: page.items, continuation: nil, loadMoreError: nil))
    }

    /// 会话变化（reset）后重新允许一次复核后的自动重载。
    @Test
    @MainActor
    func resetStartsANewRevalidationSession() async {
        let page = WatchHistoryPage(items: [item("BV1HistoryA1")], continuation: nil)
        let repository = HistoryRepositoryStub(
            results: [
                .failure(ContentApplicationError.authenticationInvalid),
                .failure(ContentApplicationError.authenticationInvalid),
                .failure(ContentApplicationError.authenticationInvalid),
                .success(page)
            ]
        )
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: repository)
        )
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.resumeAfterAuthenticationRevalidation()
        await model.waitForCurrentTask()

        model.reset()
        model.loadIfNeeded()
        await model.waitForCurrentTask()
        model.resumeAfterAuthenticationRevalidation()
        await model.waitForCurrentTask()

        #expect(model.state == .loaded(items: page.items, continuation: nil, loadMoreError: nil))
        #expect(await repository.observedContinuations().count == 4)
    }

    /// 会话切换时 API 丢弃在途请求。
    ///
    /// 抛出取消但本任务没被取消：不是网络失败，回到 idle 等会话确认后重新加载。
    @Test
    @MainActor
    func requestDroppedBySessionChangeReturnsToIdle() async {
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: HistoryRepositoryStub(results: [.failure(CancellationError())])
            )
        )

        model.loadIfNeeded()
        await model.waitForCurrentTask()

        #expect(model.state == .idle)
        #expect(!model.isBusy)
    }

    /// 复核没能确认登录状态：可重试的“无法读取登录状态”，不是网络失败。
    @Test
    @MainActor
    func authenticationRevalidationFailureLeavesRetryableHistoryState() async {
        let model = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: HistoryRepositoryStub(
                    results: [.failure(ContentApplicationError.authenticationInvalid)]
                )
            )
        )
        model.loadIfNeeded()
        await model.waitForCurrentTask()

        model.reportAuthenticationRevalidationFailure()

        #expect(model.state == .failed(.authenticationUnavailable))
        #expect(!model.isBusy)
    }
}
