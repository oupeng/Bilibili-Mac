import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 收藏夹列表按窗口账户范围读取（mid 来自账户范围，已加载时不重复请求，换 mid 先丢弃），mid 未知时给说明、未登录时
/// 丢弃；凭据可疑请求复核，复核后至多自动重载一次，不无限复核；账户变化与 `reset` 丢弃列表。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FavoriteFolderListModelTests {
    @Test
    func signedInWindowLoadsTheAccountsFoldersOnce() async {
        let repository = FavoritesRepositoryStub()
        let model = makeModel(repository, scope: .signedIn(accountID: 7))

        model.synchronize()
        await model.waitForCurrentTask()
        model.synchronize()

        #expect(model.state == .loaded(standardFolders))
        #expect(await repository.ownerIDs == [7])
    }

    @Test
    func unknownAccountShowsTheExplanationWithoutReading() async {
        let repository = FavoritesRepositoryStub()
        let model = makeModel(repository, scope: .signedIn(accountID: nil))

        model.synchronize()

        #expect(model.state == .accountUnidentified)
        #expect(await repository.ownerIDs.isEmpty)
    }

    @Test
    func signingOutDiscardsTheFolders() async {
        let repository = FavoritesRepositoryStub()
        let window = WindowScope(.signedIn(accountID: 7))
        let model = FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { window.scope }
        )
        model.synchronize()
        await model.waitForCurrentTask()

        window.scope = .signedOut
        model.synchronizeAuthenticationSession()

        #expect(model.state == .idle)
        #expect(model.folders.isEmpty)
        #expect(await repository.ownerIDs == [7])
    }

    @Test
    func anotherAccountReplacesTheFolders() async {
        let repository = FavoritesRepositoryStub()
        let window = WindowScope(.signedIn(accountID: 7))
        let model = FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { window.scope }
        )
        model.synchronize()
        await model.waitForCurrentTask()

        window.scope = .signedIn(accountID: 8)
        model.synchronize()
        await model.waitForCurrentTask()

        #expect(await repository.ownerIDs == [7, 8])
        #expect(model.state == .loaded(standardFolders))
    }

    /// 自己视角下没有默认收藏夹（Cookie 悄悄退化为访客视角）：请求复核，确认仍登录后重载一次；仍然如此时只显示可重试的
    /// 失败，不再自动重载。
    @Test
    func suspiciousListRevalidatesAndReloadsAtMostOnce() async {
        let repository = FavoritesRepositoryStub(folders: .success([]))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))

        model.synchronize()
        await model.waitForCurrentTask()
        #expect(model.state == .failed(.authenticationInvalid))
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.isAwaitingAuthenticationRevalidation)

        model.authenticationRevalidationSucceeded()
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 2)

        model.authenticationRevalidationSucceeded()
        await model.waitForCurrentTask()

        #expect(await repository.ownerIDs == [7, 7])
        #expect(model.state == .failed(.authenticationInvalid))
        #expect(ContentApplicationError.authenticationInvalid.isRetryable)

        await repository.setFolders(.success(standardFolders))
        model.reload()
        await model.waitForCurrentTask()
        #expect(model.state == .loaded(standardFolders))
    }

    @Test
    func failedRevalidationOffersARetryableFailure() async {
        let repository = FavoritesRepositoryStub(folders: .failure(.authenticationInvalid))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))
        model.synchronize()
        await model.waitForCurrentTask()

        model.authenticationRevalidationFailed()

        #expect(model.state == .failed(.authenticationUnavailable))
        #expect(!model.isAwaitingAuthenticationRevalidation)
    }

    @Test
    func resetDiscardsTheListButKeepsTheRevalidationGeneration() async {
        let repository = FavoritesRepositoryStub(folders: .failure(.authenticationInvalid))
        let model = makeModel(repository, scope: .signedIn(accountID: 7))
        model.synchronize()
        await model.waitForCurrentTask()

        model.reset()

        #expect(model.state == .idle)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(!model.isAwaitingAuthenticationRevalidation)
    }

    private func makeModel(
        _ repository: FavoritesRepositoryStub,
        scope: AccountSessionScope
    ) -> FavoriteFolderListModel {
        FavoriteFolderListModel(
            useCase: FavoritesUseCase(repository: repository),
            accountScope: { scope }
        )
    }
}

/// 测试里可改的窗口账户范围。
@MainActor
private final class WindowScope {
    var scope: AccountSessionScope

    init(_ scope: AccountSessionScope) {
        self.scope = scope
    }
}
