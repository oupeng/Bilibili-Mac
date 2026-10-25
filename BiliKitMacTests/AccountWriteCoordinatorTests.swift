import BiliAPI
import BiliApplication
import BiliAuthFeature
import BiliLibraryFeature
import BiliModels
import Testing

@testable import BiliKit

/// 账户写入只在窗口账户可信（已登录且 mid 已知、不在复核、没有待复核的外部换号）时发出，并绑定该账户；成功后给出结果
/// 并让本窗口与其他窗口的稍后再看在下次出现时刷新（本窗口乐观移除过的不再刷新）；稍后再看页的移除先在本地删掉、失败
/// 放回原位；凭据类失败只请求一次复核，直到下一次写入成功；关窗后不再接受意图。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AccountWriteCoordinatorTests {
    @Test(arguments: [
        (AccountSessionScope.signedIn(accountID: 7), false, AccountSessionScope.unresolved, true),
        (.signedIn(accountID: 7), false, .signedIn(accountID: 7), true),
        (.signedIn(accountID: 7), true, .signedIn(accountID: 7), false),
        (.signedIn(accountID: nil), false, .unresolved, false),
        (.signedOut, false, .signedOut, false),
        (.unresolved, false, .unresolved, false),
        (.signedIn(accountID: 7), false, .signedIn(accountID: 8), false)
    ])
    func writesNeedASettledSignedInAccount(
        windowScope: AccountSessionScope,
        isRestoring: Bool,
        processScope: AccountSessionScope,
        writable: Bool
    ) {
        let accountSession = AccountSessionCoordinator()
        accountSession.publish(processScope)

        let account = WindowComposition.writableAccount(
            windowScope: windowScope,
            isRestoring: isRestoring,
            accountSession: accountSession
        )

        #expect(
            account
                == (writable
                    ? WritableAccount(accountID: 7, sessionGeneration: accountSession.generation)
                    : nil)
        )
    }

    @Test
    func addReportsSuccessAndMarksEveryWatchLaterListStale() async throws {
        let process = makeTestProcess()
        let writes = WatchLaterWriteRepositoryStub()
        let origin = try await signedInWindow(process: process, writes: writes)
        let other = try await signedInWindow(process: process)
        defer {
            origin.close()
            other.close()
        }
        await load(origin.watchLaterModel)
        await load(other.watchLaterModel)
        let originGeneration = origin.watchLaterModel.successfulReloadGeneration
        let otherGeneration = other.watchLaterModel.successfulReloadGeneration

        #expect(origin.accountWrites.isWritable)
        origin.accountWrites.addToWatchLater(bvid: "BV17x411w7KC")
        await waitForObservedState { origin.accountWrites.report != nil }

        #expect(await writes.calls == ["add BV17x411w7KC 7"])
        #expect(
            origin.accountWrites.report
                == AccountWriteReport(change: .watchLaterAdded(try target()), failure: nil)
        )
        // 只标记过期：下次页面出现时才读取。
        #expect(origin.watchLaterModel.successfulReloadGeneration == originGeneration)
        await load(origin.watchLaterModel)
        await load(other.watchLaterModel)
        #expect(origin.watchLaterModel.successfulReloadGeneration == originGeneration &+ 1)
        #expect(other.watchLaterModel.successfulReloadGeneration == otherGeneration &+ 1)
    }

    @Test
    func removalIsOptimisticAndRollsBackOnFailure() async throws {
        let writes = WatchLaterWriteRepositoryStub(outcomes: [.listFull, nil])
        let window = try await signedInWindow(
            process: makeTestProcess(),
            writes: writes,
            watchLater: ["BV17x411w7KC", "BV1xx411c7mD"]
        )
        defer { window.close() }
        await load(window.watchLaterModel)

        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        #expect(bvids(window.watchLaterModel) == ["BV1xx411c7mD"])
        await waitForObservedState { window.accountWrites.report != nil }
        #expect(bvids(window.watchLaterModel) == ["BV17x411w7KC", "BV1xx411c7mD"])
        #expect(window.accountWrites.report?.failure == .listFull)
        #expect(window.accountWrites.authenticationRevalidationGeneration == 0)

        let generation = window.watchLaterModel.successfulReloadGeneration
        let sequence = window.accountWrites.reportSequence
        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        await waitForObservedState { window.accountWrites.reportSequence != sequence }
        #expect(window.accountWrites.report?.failure == nil)
        #expect(bvids(window.watchLaterModel) == ["BV1xx411c7mD"])
        // 本窗口已经乐观移除，成功后不再标记过期、不再刷新。
        await load(window.watchLaterModel)
        #expect(window.watchLaterModel.successfulReloadGeneration == generation)
        #expect(await writes.calls == ["remove BV17x411w7KC 7", "remove BV17x411w7KC 7"])
    }

    @Test
    func credentialFailuresRequestOneRevalidationUntilAWriteSucceeds() async throws {
        let writes = WatchLaterWriteRepositoryStub(
            outcomes: [.authenticationInvalid, .authenticationRequired, nil, .authenticationInvalid]
        )
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)
        defer { window.close() }
        let coordinator = window.accountWrites
        let expectedGenerations = [1, 1, 1, 2]

        for expected in expectedGenerations {
            let sequence = coordinator.reportSequence
            coordinator.addToWatchLater(bvid: "BV17x411w7KC")
            await waitForObservedState { coordinator.reportSequence != sequence }
            #expect(coordinator.authenticationRevalidationGeneration == expected)
        }
    }

    /// 节流只在同一账户与会话代次里生效：换号或登出再登录后，第一次凭据类失败照常请求复核。
    @Test
    func revalidationThrottleExpiresWithTheSession() async throws {
        let writes = WatchLaterWriteRepositoryStub(
            outcomes: [.authenticationInvalid, .authenticationInvalid, .authenticationInvalid]
        )
        let session = MutableWritableAccount()
        let coordinator = AccountWriteCoordinator(
            watchLater: WatchLaterWriteUseCase(repository: writes),
            watchLaterModel: WatchLaterViewModel(
                useCase: WatchLaterUseCase(repository: WatchLaterRepositoryStub())
            ),
            writableAccount: { session.account },
            publish: { _, _ in }
        )
        defer { coordinator.close() }

        for (generation, expected) in [(UInt64(1), 1), (1, 1), (3, 2)] {
            session.account = WritableAccount(accountID: 7, sessionGeneration: generation)
            let sequence = coordinator.reportSequence
            coordinator.addToWatchLater(bvid: "BV17x411w7KC")
            await waitForObservedState { coordinator.reportSequence != sequence }
            #expect(coordinator.authenticationRevalidationGeneration == expected)
        }
    }

    @Test
    func closedGateSendsNothing() async throws {
        let writes = WatchLaterWriteRepositoryStub()
        let window = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(watchLaterWrite: writes)
        )
        window.authenticationModel.restoreIfNeeded()
        await window.authenticationModel.waitForCurrentTask()

        #expect(!window.accountWrites.isWritable)
        window.accountWrites.addToWatchLater(bvid: "BV17x411w7KC")
        window.accountWrites.removeFromWatchLater(bvid: "BV17x411w7KC")
        window.close()

        #expect(await writes.calls.isEmpty)
        #expect(window.accountWrites.report == nil)
    }

    /// 其他账户或旧会话代次的效果不落到本窗口。
    @Test
    func effectsOfAnotherAccountOrSessionAreDropped() async throws {
        let window = try await signedInWindow(process: makeTestProcess())
        defer { window.close() }
        await load(window.watchLaterModel)
        let generation = window.watchLaterModel.successfulReloadGeneration
        let router = AccountWriteEffectRouter(
            watchLaterModel: window.watchLaterModel,
            writableAccount: { WritableAccount(accountID: 7, sessionGeneration: 3) }
        )

        for delivery in [
            AccountWriteEffectDelivery(
                effect: AccountWriteEffect(accountID: 8, change: .watchLaterAdded(try target())),
                sessionGeneration: 3
            ),
            AccountWriteEffectDelivery(
                effect: AccountWriteEffect(accountID: 7, change: .watchLaterAdded(try target())),
                sessionGeneration: 2
            )
        ] {
            router.apply(delivery, appliedLocally: false)
        }
        await load(window.watchLaterModel)

        #expect(window.watchLaterModel.successfulReloadGeneration == generation)
    }

    /// 关窗取消在途写入：之后不显示结果，也不再接受新的意图。
    @Test
    func closingCancelsInFlightWrites() async throws {
        let writes = WatchLaterWriteRepositoryStub(holdsWrites: true)
        let window = try await signedInWindow(process: makeTestProcess(), writes: writes)

        window.accountWrites.addToWatchLater(bvid: "BV17x411w7KC")
        await writes.waitForCallCount(1)
        window.close()
        await writes.releaseWrites()
        window.accountWrites.addToWatchLater(bvid: "BV1xx411c7mD")

        #expect(!window.accountWrites.isWritable)
        #expect(window.accountWrites.report == nil)
        #expect(await writes.calls == ["add BV17x411w7KC 7"])
    }

    @Test
    func onlyTheWindowAPIGetsTheExactWriteCapability() async throws {
        #expect(
            LiveAPIClients.mainAccountWriteAllowedPaths == [
                "/x/v2/history/toview/add",
                "/x/v2/history/toview/del"
            ]
        )
        #expect(BiliAccountWritePath.watchLaterAdd == "/x/v2/history/toview/add")
        #expect(BiliAccountWritePath.watchLaterRemove == "/x/v2/history/toview/del")
        // 测速与观看进度 writer 没有账户写授权器：在发请求前就失败。
        for client in [LiveAPIClients.cdnBenchmark(), LiveAPIClients.watchProgressWriter()] {
            await #expect(throws: BiliAPIError.authorizationRequired) {
                try await client.addToWatchLater(bvid: "BV17x411w7KC", accountID: 7)
            }
        }
    }

    private func signedInWindow(
        process: ProcessComposition,
        writes: WatchLaterWriteRepositoryStub = WatchLaterWriteRepositoryStub(),
        watchLater bvids: [String] = []
    ) async throws -> WindowComposition {
        let window = WindowComposition(
            process: process,
            adapters: makeTestAdapters(
                watchLater: WatchLaterRepositoryStub(bvids: bvids),
                watchLaterWrite: writes,
                authentication: AuthenticationServiceStub(
                    restoreState: .signedIn(
                        AccountIdentity(id: 7, displayName: "账号", avatarURL: nil)
                    )
                )
            )
        )
        window.authenticationModel.restoreIfNeeded()
        await window.authenticationModel.waitForCurrentTask()
        window.open()
        return window
    }

    private func load(_ model: WatchLaterViewModel) async {
        model.loadIfNeeded()
        await model.waitForCurrentTask()
    }

    private func bvids(_ model: WatchLaterViewModel) -> [String] {
        guard case .loaded(let items, _, _) = model.state else { return [] }
        return items.map(\.bvid)
    }

    private func target() throws -> VideoWriteTarget {
        try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
    }
}

/// 测试里可变的窗口写入账户；门槛闭包在主线程读取。
@MainActor
private final class MutableWritableAccount {
    var account: WritableAccount?
}
