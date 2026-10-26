import BiliApplication
import Testing

/// 收藏写入只为正数账户发请求，成功时给出带账户的效果；归属改动必须真有改动、两侧不相交，夹 id 升序以便去重；夹内条目
/// 的 ID 都须为正数。
@Suite(.timeLimit(.minutes(1)))
struct FavoritesWriteUseCaseTests {
    @Test
    func successfulWritesReportTheirEffect() async throws {
        let repository = FavoritesWriteRepositoryStub()
        let useCase = FavoritesWriteUseCase(repository: repository)
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let change = try #require(
            FavoriteMembershipChange(target: target, adding: [12, 11], removing: [3])
        )
        let entry = try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001))

        let updated = try await useCase.update(change, accountID: 42)
        let removed = try await useCase.remove(entry, accountID: 42)

        #expect(
            updated == AccountWriteEffect(accountID: 42, change: .favoriteMembershipChanged(change))
        )
        #expect(
            removed == AccountWriteEffect(accountID: 42, change: .removedFromFavoriteFolder(entry))
        )
        #expect(
            await repository.calls == [
                "update BV17x411w7KC +[11, 12] -[3] 42", "remove 170001 from 10 42"
            ]
        )
    }

    @Test(arguments: [Int64(0), -7])
    func nonPositiveAccountSendsNothing(accountID: Int64) async throws {
        let repository = FavoritesWriteRepositoryStub()
        let useCase = FavoritesWriteUseCase(repository: repository)

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.remove(
                try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001)),
                accountID: accountID
            )
        }
        #expect(await repository.calls.isEmpty)
    }

    @Test
    func failuresPropagateWithoutAnEffect() async throws {
        let repository = FavoritesWriteRepositoryStub(failure: .listFull)
        let useCase = FavoritesWriteUseCase(repository: repository)

        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let change = try #require(
            FavoriteMembershipChange(target: target, adding: [11], removing: [])
        )

        await #expect(throws: AccountWriteError.listFull) {
            try await useCase.update(change, accountID: 42)
        }
    }

    @Test(
        arguments: [
            ([], []),
            ([11], [11]),
            ([0], []),
            ([], [-1])
        ] as [(Set<Int64>, Set<Int64>)]
    )
    func changesWithoutAValidDifferenceAreNil(adding: Set<Int64>, removing: Set<Int64>) throws {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        #expect(FavoriteMembershipChange(target: target, adding: adding, removing: removing) == nil)
    }

    @Test(arguments: [(Int64(0), Int64(1)), (1, 0), (-1, 1)])
    func entriesNeedPositiveIDs(folderID: Int64, videoAID: Int64) {
        #expect(FavoriteFolderEntry(folderID: folderID, videoAID: videoAID) == nil)
    }
}

/// 本 target 唯一的 `FavoritesWriteRepository` 替身：记录调用，按配置成功或失败。
private actor FavoritesWriteRepositoryStub: FavoritesWriteRepository {
    private let failure: AccountWriteError?
    private(set) var calls: [String] = []

    init(failure: AccountWriteError? = nil) {
        self.failure = failure
    }

    func update(_ change: FavoriteMembershipChange, accountID: Int64) async throws {
        calls.append(
            "update \(change.target.bvid) +\(change.addedFolderIDs) -\(change.removedFolderIDs) \(accountID)"
        )
        if let failure { throw failure }
    }

    func remove(_ entry: FavoriteFolderEntry, accountID: Int64) async throws {
        calls.append("remove \(entry.videoAID) from \(entry.folderID) \(accountID)")
        if let failure { throw failure }
    }
}
