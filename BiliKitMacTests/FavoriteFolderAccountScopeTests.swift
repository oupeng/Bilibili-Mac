import BiliApplication
import BiliAuthFeature
import BiliLibraryFeature
import BiliModels
import Testing

@testable import BiliKit

/// 收藏夹列表只在窗口账户范围可信时读取：认证仍在确认、或其他窗口换号而本窗口还没复核到时不发请求（否则会用新账户的
/// Cookie 读旧账户的 mid）；外部复核结束、本窗口范围不变时重新读取。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct FavoriteFolderAccountScopeTests {
    @Test(arguments: [
        // 进程还没发布过范围：没有外部变化。
        (AccountSessionScope.unresolved, false, AccountSessionScope.signedIn(accountID: 7)),
        (.signedIn(accountID: 7), false, .signedIn(accountID: 7)),
        // 其他窗口已换号或登出，本窗口还没复核到。
        (.signedIn(accountID: 8), false, .unresolved),
        (.signedOut, false, .unresolved),
        // 本窗口仍在确认登录状态。
        (.signedIn(accountID: 7), true, .unresolved)
    ])
    func readingScopeWaitsForRevalidation(
        processScope: AccountSessionScope,
        isRestoring: Bool,
        expected: AccountSessionScope
    ) {
        let accountSession = AccountSessionCoordinator()
        accountSession.publish(processScope)

        #expect(
            WindowComposition.settledAccountScope(
                windowScope: .signedIn(accountID: 7),
                isRestoring: isRestoring,
                accountSession: accountSession
            ) == expected
        )
    }

    @Test
    func externalAccountChangeDefersTheListUntilRevalidationFinishes() async {
        let favorites = FavoritesRepositoryStub()
        let owner = WindowComposition(
            process: makeTestProcess(),
            adapters: makeTestAdapters(
                favorites: favorites,
                authentication: AuthenticationServiceStub(
                    restoreState: .signedIn(
                        AccountIdentity(id: 7, displayName: "账号", avatarURL: nil)
                    )
                )
            )
        )
        owner.authenticationModel.restoreIfNeeded()
        await owner.authenticationModel.waitForCurrentTask()
        owner.favoriteFolderList.synchronize()
        await waitForObservedState {
            if case .loaded = owner.favoriteFolderList.state { return true }
            return false
        }

        // 其他窗口换号：本窗口先丢弃要求账户的内容，复核结束前导航侧栏重建触发的对齐不读取。
        owner.process.accountSession.publish(.signedIn(accountID: 8))
        owner.sources.resetAccountContent()
        owner.favoriteFolderList.synchronize()
        #expect(owner.favoriteFolderList.state == .idle)

        // 复核结束，本窗口范围不变且与进程一致：重新读取。
        owner.process.accountSession.publish(.signedIn(accountID: 7))
        owner.externalSessionRevalidationDidFinish()
        await favorites.waitForFolderRequestCount(2)

        #expect(await favorites.folderOwnerIDs == [7, 7])
    }
}
