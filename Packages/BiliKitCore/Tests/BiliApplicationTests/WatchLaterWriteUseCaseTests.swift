import BiliApplication
import Testing

/// 稍后再看写入只为合法 BVID 与正数账户发请求，成功时给出带账户的效果；只有凭据类失败要求复核账户。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterWriteUseCaseTests {
    @Test
    func successfulWritesReportTheirEffect() async throws {
        let repository = WatchLaterWriteRepositoryStub()
        let useCase = WatchLaterWriteUseCase(repository: repository)
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        let added = try await useCase.add(target, accountID: 42)
        let removed = try await useCase.remove(target, accountID: 42)

        #expect(added == AccountWriteEffect(accountID: 42, change: .watchLaterAdded(target)))
        #expect(removed == AccountWriteEffect(accountID: 42, change: .watchLaterRemoved(target)))
        #expect(await repository.calls == ["add BV17x411w7KC 42", "remove BV17x411w7KC 42"])
    }

    @Test(arguments: [Int64(0), -7])
    func nonPositiveAccountSendsNothing(accountID: Int64) async throws {
        let repository = WatchLaterWriteRepositoryStub()
        let useCase = WatchLaterWriteUseCase(repository: repository)
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.add(target, accountID: accountID)
        }
        await #expect(throws: AccountWriteError.invalidRequest) {
            try await useCase.remove(target, accountID: accountID)
        }
        #expect(await repository.calls.isEmpty)
    }

    @Test
    func failuresPropagateWithoutAnEffect() async throws {
        let repository = WatchLaterWriteRepositoryStub(failure: .listFull)
        let useCase = WatchLaterWriteUseCase(repository: repository)

        await #expect(throws: AccountWriteError.listFull) {
            try await useCase.add(try #require(VideoWriteTarget(bvid: "BV17x411w7KC")), accountID: 42)
        }
    }

    @Test(arguments: ["", "av170001", "BV", "BV1é", "BV1/../x"])
    func invalidBVIDHasNoTarget(bvid: String) {
        #expect(VideoWriteTarget(bvid: bvid) == nil)
    }

    @Test
    func onlyCredentialFailuresRequestRevalidation() {
        let all: [AccountWriteError] = [
            .invalidRequest, .authenticationRequired, .authenticationInvalid,
            .authenticationUnavailable, .restricted, .listFull, .contentUnavailable,
            .rejected(code: 1), .unavailable
        ]
        #expect(
            all.filter(\.requiresAccountRevalidation)
                == [.authenticationRequired, .authenticationInvalid]
        )
        #expect(
            all.filter(\.isRetryable)
                == [.authenticationUnavailable, .rejected(code: 1), .unavailable]
        )
    }
}

/// 本 target 唯一的 `WatchLaterWriteRepository` 替身：记录调用，按配置成功或失败。
actor WatchLaterWriteRepositoryStub: WatchLaterWriteRepository {
    private let failure: AccountWriteError?
    private(set) var calls: [String] = []

    init(failure: AccountWriteError? = nil) {
        self.failure = failure
    }

    func add(_ target: VideoWriteTarget, accountID: Int64) async throws {
        calls.append("add \(target.bvid) \(accountID)")
        if let failure { throw failure }
    }

    func remove(_ target: VideoWriteTarget, accountID: Int64) async throws {
        calls.append("remove \(target.bvid) \(accountID)")
        if let failure { throw failure }
    }
}
