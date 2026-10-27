import BiliApplication
import BiliModels
import Foundation
import Testing

/// 收藏夹用例：非正的账户或不合法的请求不发请求；没有默认收藏夹的列表按凭据失效报告（Cookie 失效时接口悄悄退化为
/// 访客视角）；夹内页码与请求不符按无效响应，同页重复条目只保留第一条。
@Suite(.timeLimit(.minutes(1)))
struct FavoritesUseCaseTests {
    @Test
    func foldersWithADefaultFolderAreReturnedInOrder() async throws {
        let folders = [folder(2, isDefault: false), folder(1, isDefault: true)]
        let repository = FavoritesRepositoryStub(folders: folders)

        let result = try await FavoritesUseCase(repository: repository).folders(ownerID: 10_001)

        #expect(result == folders)
        #expect(await repository.ownerIDs == [10_001])
    }

    @Test(arguments: [[], [folder(2, isDefault: false)]] as [[FavoriteFolder]])
    func foldersWithoutADefaultFolderAreSuspectedCredentials(folders: [FavoriteFolder]) async {
        let repository = FavoritesRepositoryStub(folders: folders)

        await #expect(throws: ContentApplicationError.authenticationInvalid) {
            try await FavoritesUseCase(repository: repository).folders(ownerID: 10_001)
        }
    }

    /// 面板的归属读取与列表同一套校验：没有默认收藏夹按凭据失效报告。
    @Test
    func membershipsKeepOrderAndRequireADefaultFolder() async throws {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let repository = FavoritesRepositoryStub(
            folders: [folder(2, isDefault: false), folder(1, isDefault: true)],
            containingFolderIDs: [1]
        )

        let memberships = try await FavoritesUseCase(repository: repository).memberships(
            of: target,
            ownerID: 10_001
        )

        #expect(memberships.map(\.id) == [2, 1])
        #expect(memberships.map(\.containsVideo) == [false, true])
        await #expect(throws: ContentApplicationError.authenticationInvalid) {
            try await FavoritesUseCase(
                repository: FavoritesRepositoryStub(folders: [folder(2, isDefault: false)])
            ).memberships(of: target, ownerID: 10_001)
        }
    }

    @Test(arguments: [Int64(0), -1])
    func nonPositiveOwnerSendsNothing(ownerID: Int64) async {
        let repository = FavoritesRepositoryStub(folders: [folder(1, isDefault: true)])

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await FavoritesUseCase(repository: repository).folders(ownerID: ownerID)
        }
        #expect(await repository.ownerIDs.isEmpty)
    }

    @Test
    func pageDropsRepeatedItemsWithinThePage() async throws {
        let repository = FavoritesRepositoryStub(
            page: FavoriteFolderPage(
                items: [item("BV1A"), item("BV1B"), item("BV1A")],
                pageNumber: 2,
                pageSize: 40,
                totalCount: 45,
                hasMore: false
            )
        )
        let request = FavoriteFolderRequest(folderID: 3001, keyword: " 猫 ", page: 2)

        let result = try await FavoritesUseCase(repository: repository).page(request)

        #expect(result.items.map(\.id) == ["BV1A", "BV1B"])
        #expect(result.totalCount == 45)
        #expect(await repository.requests == [request])
        #expect(request.keyword == "猫")
    }

    @Test(arguments: [
        FavoriteFolderRequest(folderID: 0),
        FavoriteFolderRequest(folderID: 3001, page: 0),
        FavoriteFolderRequest(folderID: 3001, keyword: String(repeating: "长", count: 101))
    ])
    func invalidPageRequestSendsNothing(request: FavoriteFolderRequest) async {
        let repository = FavoritesRepositoryStub()

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await FavoritesUseCase(repository: repository).page(request)
        }
        #expect(await repository.requests.isEmpty)
    }

    @Test
    func misplacedPageIsAnInvalidResponse() async {
        let repository = FavoritesRepositoryStub(
            page: FavoriteFolderPage(
                items: [],
                pageNumber: 3,
                pageSize: 40,
                totalCount: 0,
                hasMore: false
            )
        )

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await FavoritesUseCase(repository: repository).page(
                FavoriteFolderRequest(folderID: 3001, page: 2)
            )
        }
    }
}

/// 本 target 唯一的 `FavoritesRepository` 替身：返回固定的列表与页（视频在 `containingFolderIDs` 的夹里），并记录请求。
private actor FavoritesRepositoryStub: FavoritesRepository {
    private(set) var ownerIDs: [Int64] = []
    private(set) var requests: [FavoriteFolderRequest] = []
    private let folders: [FavoriteFolder]
    private let containingFolderIDs: Set<Int64>
    private let page: FavoriteFolderPage

    init(
        folders: [FavoriteFolder] = [],
        containingFolderIDs: Set<Int64> = [],
        page: FavoriteFolderPage = FavoriteFolderPage(
            items: [],
            pageNumber: 1,
            pageSize: 40,
            totalCount: 0,
            hasMore: false
        )
    ) {
        self.folders = folders
        self.containingFolderIDs = containingFolderIDs
        self.page = page
    }

    func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        ownerIDs.append(ownerID)
        return folders
    }

    func favoriteFolderMemberships(
        ownerID: Int64,
        video: VideoWriteTarget
    ) async throws -> [FavoriteFolderMembership] {
        ownerIDs.append(ownerID)
        return folders.map {
            FavoriteFolderMembership(folder: $0, containsVideo: containingFolderIDs.contains($0.id))
        }
    }

    func favoriteFolderPage(request: FavoriteFolderRequest) async throws -> FavoriteFolderPage {
        requests.append(request)
        return page
    }
}

private func folder(_ id: Int64, isDefault: Bool) -> FavoriteFolder {
    FavoriteFolder(
        id: id,
        title: "收藏夹 \(id)",
        mediaCount: 1,
        isPrivate: false,
        isDefault: isDefault
    )
}

private func item(_ id: String) -> FavoriteItem {
    FavoriteItem(
        id: id,
        title: id,
        coverURL: nil,
        owner: VideoOwner(id: 1, name: "作者"),
        durationSeconds: 60,
        favoritedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}
