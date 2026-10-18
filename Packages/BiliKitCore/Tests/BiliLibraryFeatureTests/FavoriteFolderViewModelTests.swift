import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 收藏夹页面：选夹、换夹、换排序、提交或清空关键词与翻页都从请求的页整体替换并丢弃旧在途结果，换夹清空关键词、
/// 保留排序；每次替换成功刷新代次前进；刷新原地重读当前页、失败保留内容；收藏夹不存在时重读列表并回落到默认收藏夹；
/// 不在本页时只改选择不读取；凭据失败请求复核，离开再回来重新读取；账户变化丢弃选择，仍在本页时选新账户的默认收藏夹。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FavoriteFolderViewModelTests {
    @Test
    func selectingAFolderLoadsItsFirstPage() async {
        let (model, repository, _) = await makeModels()

        model.selectFolder(10)
        await model.waitForCurrentTask()

        #expect(await repository.requests == [FavoriteFolderRequest(folderID: 10)])
        #expect(model.selectedFolder?.title == "默认收藏夹")
        #expect(model.currentPage == 1)
        #expect(model.pageCount == 3)
        #expect(model.totalCount == 90)
        #expect(model.successfulReloadGeneration == 1)
        guard case .loaded(1, let content) = model.phase else {
            Issue.record("expected the first page, got \(model.phase)")
            return
        }
        #expect(content.items.map(\.id) == ["BV1F10P1"])
    }

    @Test
    func switchingFoldersDiscardsTheInFlightPageClearsTheKeywordAndKeepsTheOrder() async throws {
        let (model, repository, _) = await makeModels(heldFolderIDs: [20])
        model.selectFolder(10)
        await model.waitForCurrentTask()
        model.orderSelection = .mostPlayed
        model.selectOrder(.mostPlayed)
        model.searchDraft = "猫"
        model.submitSearch()
        await model.waitForCurrentTask()
        model.selectFolder(20)
        try await repository.waitForPageCalls(4)

        model.selectFolder(30)
        await model.waitForCurrentTask()
        await repository.releaseHeldPages()

        #expect(model.selectedFolderID == 30)
        #expect(model.appliedKeyword.isEmpty)
        #expect(model.searchDraft.isEmpty)
        #expect(model.appliedOrder == .mostPlayed)
        #expect(
            await repository.requests.last
                == FavoriteFolderRequest(folderID: 30, order: .mostPlayed)
        )
        guard case .loaded(1, let content) = model.phase else {
            Issue.record("expected folder 30, got \(model.phase)")
            return
        }
        #expect(content.items.map(\.id) == ["BV1F30P1"])
    }

    @Test
    func conditionsReplaceTheContentFromTheFirstPage() async {
        let (model, repository, _) = await makeModels()
        model.selectFolder(10)
        await model.waitForCurrentTask()
        model.showPage(2)
        await model.waitForCurrentTask()

        model.selectOrder(.recentlyPublished)
        await model.waitForCurrentTask()
        model.searchDraft = " 猫 "
        model.submitSearch()
        await model.waitForCurrentTask()
        model.searchDraft = ""
        await model.waitForCurrentTask()

        #expect(
            await repository.requests == [
                FavoriteFolderRequest(folderID: 10),
                FavoriteFolderRequest(folderID: 10, page: 2),
                FavoriteFolderRequest(folderID: 10, order: .recentlyPublished),
                FavoriteFolderRequest(folderID: 10, order: .recentlyPublished, keyword: "猫"),
                FavoriteFolderRequest(folderID: 10, order: .recentlyPublished)
            ]
        )
        #expect(model.successfulReloadGeneration == 5)
        #expect(model.currentPage == 1)
    }

    @Test
    func pagerKeepsTheTotalsWhileAPageLoadsAndIgnoresOutOfRangePages() async throws {
        let (model, repository, _) = await makeModels()
        model.selectFolder(10)
        await model.waitForCurrentTask()

        model.showPage(4)
        model.showPage(1)
        #expect(await repository.requests.count == 1)

        await repository.setPage { _ in .failure(.transportFailure) }
        model.showPage(3)
        #expect(model.phase == .loading(page: 3))
        #expect(model.pageCount == 3)
        await model.waitForCurrentTask()
        #expect(model.phase == .failed(page: 3, error: .transportFailure))
        #expect(model.totalCount == 90)

        await repository.setPage { .success(favoritePage($0, total: 90)) }
        model.reload()
        await model.waitForCurrentTask()
        #expect(await repository.requests.map(\.page) == [1, 3, 3])
    }

    /// 刷新原地重读当前页：失败时保留内容并给出原因，成功后整体替换、刷新代次前进。
    @Test
    func refreshKeepsTheContentAndReportsAFailure() async {
        let (model, repository, _) = await makeModels()
        model.selectFolder(10)
        await model.waitForCurrentTask()
        model.showPage(2)
        await model.waitForCurrentTask()

        await repository.setPage { _ in .failure(.transportFailure) }
        model.reload()
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.refreshError == .transportFailure)
        #expect(!model.isRefreshing)
        guard case .loaded(2, _) = model.phase else {
            Issue.record("expected the kept page, got \(model.phase)")
            return
        }

        await repository.setPage { .success(favoritePage($0, total: 90)) }
        model.reload()
        await model.waitForCurrentTask()
        #expect(model.refreshError == nil)
        #expect(model.successfulReloadGeneration == 3)
        #expect(await repository.requests.map(\.page) == [1, 2, 2, 2])
    }

    @Test
    func missingFolderReloadsTheListAndFallsBackToTheDefaultFolder() async throws {
        let (model, repository, folderList) = await makeModels()
        model.activate()
        model.selectFolder(30)
        await model.waitForCurrentTask()
        await repository.setFolders(.success(Array(standardFolders.dropFirst())))
        await repository.setPage { request in
            request.folderID == 30
                ? .failure(.contentUnavailable) : .success(favoritePage(request, total: 1))
        }

        model.reload()
        await model.waitForCurrentTask()
        try await repository.waitForFolderCalls(2)
        await waitUntilSettled(folderList)
        await model.waitForCurrentTask()

        #expect(model.selectedFolderID == 10)
        #expect(await repository.requests.last == FavoriteFolderRequest(folderID: 10))
    }

    /// 不在本页时列表变化只改选择，不读取；回来时才加载。
    @Test
    func fallbackOffThePageOnlyChangesTheSelection() async {
        let (model, repository, folderList) = await makeModels()
        model.selectFolder(30)
        await model.waitForCurrentTask()
        model.deactivateRoute()
        await repository.setFolders(.success(Array(standardFolders.dropFirst())))

        folderList.reload()
        await waitUntilSettled(folderList)

        #expect(model.selectedFolderID == 10)
        #expect(model.phase == .idle)
        #expect(await repository.requests.map(\.folderID) == [30])

        model.activate()
        await model.waitForCurrentTask()
        #expect(await repository.requests.map(\.folderID) == [30, 10])
    }

    @Test
    func credentialFailureRequestsRevalidationAndReloadsOnReturn() async {
        let (model, repository, _) = await makeModels()
        await repository.setPage { _ in .failure(.authenticationInvalid) }
        model.selectFolder(10)
        model.activate()
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(model.isAwaitingAuthenticationRevalidation)

        model.deactivateRoute()
        #expect(!model.isAwaitingAuthenticationRevalidation)
        await repository.setPage { .success(favoritePage($0, total: 1)) }
        model.activate()
        await model.waitForCurrentTask()

        guard case .loaded = model.phase else {
            Issue.record("expected a reload on return, got \(model.phase)")
            return
        }
        #expect(await repository.requests.count == 2)
    }

    /// 换号后仍在本页：选择与条件被丢弃，新账户的收藏夹列表到达后选中它的默认收藏夹。
    @Test
    func accountChangeOnThePageSelectsTheNewDefaultFolder() async throws {
        let (model, repository, folderList) = await makeModels()
        model.activate()
        model.selectFolder(30)
        model.searchDraft = "猫"
        model.submitSearch()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession()
        #expect(model.selectedFolderID == nil)
        #expect(model.appliedKeyword.isEmpty)
        folderList.synchronizeAuthenticationSession()
        await waitUntilSettled(folderList)
        await model.waitForCurrentTask()

        #expect(model.selectedFolderID == 10)
        #expect(await repository.requests.last == FavoriteFolderRequest(folderID: 10))
    }

    @Test
    func resetDiscardsTheSelectionAndContent() async {
        let (model, _, _) = await makeModels()
        model.selectFolder(10)
        await model.waitForCurrentTask()

        model.reset()

        #expect(model.selectedFolderID == nil)
        #expect(model.phase == .idle)
        #expect(model.totalCount == nil)
        #expect(model.appliedOrder == .recentlyFavorited)
    }

    private func makeModels(
        heldFolderIDs: Set<Int64> = []
    ) async -> (FavoriteFolderViewModel, FavoritesRepositoryStub, FavoriteFolderListModel) {
        let repository = FavoritesRepositoryStub(heldFolderIDs: heldFolderIDs)
        let useCase = FavoritesUseCase(repository: repository)
        let folderList = FavoriteFolderListModel(
            useCase: useCase,
            accountScope: { .signedIn(accountID: 7) }
        )
        let model = FavoriteFolderViewModel(useCase: useCase, folderList: folderList)
        folderList.synchronize()
        await waitUntilSettled(folderList)
        return (model, repository, folderList)
    }
}
