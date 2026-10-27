import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 收藏写入在资料库一侧的契约：「从此收藏夹移除」只乐观移除显示中收藏夹里的那个视频条目、总数减一，回滚放回原位，
/// 内容此间被整体替换过就不放回，被替换过或仍有在途读取时也不再算作“已在本地改过”；别处改了显示中的收藏夹时，在本页
/// 就原地刷新、不回顶部，不在本页就回来时刷新；「收藏到…」面板的勾选从服务端归属开始，确认的改动只是勾选与初始归属
/// 的差异，读取遇到凭据失败时请求复核。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FavoriteFolderWriteTests {
    @Test
    func removalIsOptimisticAndRollsBackInPlace() async throws {
        let (model, _) = await makeLoadedModel()
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 2))

        let removal = try #require(model.removeItem(entry))

        #expect(displayedIDs(model) == ["BV1Item1", "BV1Item3"])
        #expect(model.totalCount == 2)
        model.restoreItem(removal)
        #expect(displayedIDs(model) == ["BV1Item1", "BV1Item2", "BV1Item3"])
        #expect(model.totalCount == 3)
    }

    @Test
    func removalOnlyTouchesTheDisplayedFolderAndItsVideoEntries() async throws {
        let (model, _) = await makeLoadedModel()
        let otherFolder = try #require(FavoriteFolderEntry(folderID: 20, videoAID: 2))
        let missingVideo = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 99))

        #expect(model.removeItem(otherFolder) == nil)
        #expect(model.removeItem(missingVideo) == nil)
        #expect(displayedIDs(model) == ["BV1Item1", "BV1Item2", "BV1Item3"])
    }

    /// 移除之后内容被重读替换：回滚不再放回旧条目。
    @Test
    func rollbackAfterAReplacementIsDropped() async throws {
        let (model, repository) = await makeLoadedModel()
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 2))
        let removal = try #require(model.removeItem(entry))
        await repository.setPage { .success(Self.page($0, aids: [1, 3])) }

        model.reload()
        await model.waitForCurrentTask()
        model.restoreItem(removal)

        #expect(displayedIDs(model) == ["BV1Item1", "BV1Item3"])
    }

    @Test
    func changesToTheDisplayedFolderRefreshItOnThePage() async throws {
        let (model, repository) = await makeLoadedModel()
        let requestsBefore = await repository.requests.count

        let generation = model.successfulReloadGeneration

        model.markNeedsReload(folderIDs: [20])
        #expect(!model.isRefreshing)
        model.markNeedsReload(folderIDs: [10, 20])
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(await repository.requests.count == requestsBefore + 1)
        // 写入引起的刷新不回顶部；工具栏刷新照常回顶部。
        #expect(model.successfulReloadGeneration == generation)
        model.reload()
        await model.waitForCurrentTask()
        #expect(model.successfulReloadGeneration == generation &+ 1)
    }

    /// 移除之后有刷新在途或已落地：写入前的快照可能把条目带回来，不能再算作“已在本地改过”。
    @Test
    func removalNoLongerCountsAsAppliedOnceAReadIntervenes() async throws {
        let (model, _) = await makeLoadedModel()
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 2))
        let removal = try #require(model.removeItem(entry))
        #expect(model.stillShowsRemoval(removal))

        model.reload()
        #expect(!model.stillShowsRemoval(removal))
        await model.waitForCurrentTask()
        #expect(!model.stillShowsRemoval(removal))
    }

    @Test
    func changesWhileAwayRefreshOnReturn() async throws {
        let (model, repository) = await makeLoadedModel()
        model.deactivateRoute()
        let requestsBefore = await repository.requests.count

        model.markNeedsReload(folderIDs: [10])
        #expect(await repository.requests.count == requestsBefore)
        model.activate()
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(await repository.requests.count == requestsBefore + 1)
        model.deactivateRoute()
        model.activate()
        #expect(!model.isRefreshing)
    }

    @Test
    func pickerStartsFromTheServerStateAndConfirmsOnlyTheDifference() async throws {
        let repository = FavoritesRepositoryStub()
        await repository.setContainingFolderIDs([10, 20])
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let picker = FavoritePickerModel(
            target: target,
            accountID: 7,
            useCase: FavoritesUseCase(repository: repository),
            onCredentialFailure: {}
        )

        picker.load()
        await waitForObservedState {
            if case .loaded = picker.phase { true } else { false }
        }
        #expect(picker.selectedFolderIDs == [10, 20])
        #expect(picker.change == nil)

        picker.setSelected(false, folderID: 20)
        picker.setSelected(true, folderID: 30)
        picker.setSelected(true, folderID: 99)
        #expect(
            picker.change
                == FavoriteMembershipChange(target: target, adding: [30], removing: [20])
        )
        picker.setSelected(true, folderID: 20)
        picker.setSelected(false, folderID: 30)
        #expect(picker.change == nil)
    }

    /// 读取失败给出可重试的失败；只有凭据缺失或失效交给协调者请求复核。
    @Test(arguments: [
        (ContentApplicationError.unavailable, 0),
        (.authenticationInvalid, 1),
        (.authenticationRequired, 1)
    ])
    func pickerReportsAReadFailure(
        failure: ContentApplicationError,
        revalidations: Int
    ) async throws {
        let repository = FavoritesRepositoryStub(folders: .failure(failure))
        let requested = RevalidationRequests()
        let picker = FavoritePickerModel(
            target: try #require(VideoWriteTarget(bvid: "BV17x411w7KC")),
            accountID: 7,
            useCase: FavoritesUseCase(repository: repository),
            onCredentialFailure: { requested.count += 1 }
        )

        picker.load()
        await waitForObservedState { picker.phase != FavoritePickerModel.Phase.loading }

        #expect(picker.phase == FavoritePickerModel.Phase.failed(failure))
        #expect(picker.change == nil)
        #expect(requested.count == revalidations)
    }

    /// 已登录、在收藏夹页上显示默认收藏夹（10）的第 1 页：三条视频条目，av 号 1–3。
    private func makeLoadedModel() async -> (FavoriteFolderViewModel, FavoritesRepositoryStub) {
        let repository = FavoritesRepositoryStub(page: { .success(Self.page($0, aids: [1, 2, 3])) })
        let useCase = FavoritesUseCase(repository: repository)
        let folderList = FavoriteFolderListModel(
            useCase: useCase,
            accountScope: { .signedIn(accountID: 7) }
        )
        let model = FavoriteFolderViewModel(useCase: useCase, folderList: folderList)
        folderList.synchronize()
        await waitUntilSettled(folderList)
        model.activate()
        await model.waitForCurrentTask()
        return (model, repository)
    }

    private nonisolated static func page(
        _ request: FavoriteFolderRequest,
        aids: [Int64]
    ) -> FavoriteFolderPage {
        FavoriteFolderPage(
            items: aids.map { favoriteItem("BV1Item\($0)", videoAID: $0) },
            pageNumber: request.page,
            pageSize: 40,
            totalCount: aids.count,
            hasMore: false
        )
    }

    private func displayedIDs(_ model: FavoriteFolderViewModel) -> [String] {
        guard case .loaded(_, let content) = model.phase else { return [] }
        return content.items.map(\.id)
    }
}

/// 面板请求账户复核的次数；回调在主线程调用。
@MainActor
private final class RevalidationRequests {
    var count = 0
}
