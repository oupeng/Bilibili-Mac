import BiliAuthFeature
import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth
@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct AccountReadAuthorizationCompositionTests {
    /// 窗口状态、复核阶段、进程状态与期望结果。
    static let signedOutConfirmationCases:
        [(AccountSessionScope, AuthenticationResolutionPhase, AccountSessionScope, Bool)] = [
            (.signedOut, .other, .unresolved, true),
            (.signedOut, .other, .signedOut, true),
            (.signedOut, .restoring, .signedOut, false),
            (.signedOut, .failed, .signedOut, false),
            (.signedOut, .other, .signedIn(accountID: 42), false),
            (.unresolved, .other, .unresolved, false),
            (.signedIn(accountID: 42), .signedIn, .signedIn(accountID: 42), false)
        ]

    /// 只有窗口已确认未登录、没有进行中或失败的复核、进程内也没有窗口登录时，Keychain 不可用才按无凭据处理。
    @Test(arguments: signedOutConfirmationCases)
    func signedOutIsConfirmedOnlyWhenNothingSuggestsAnAccount(
        windowScope: AccountSessionScope,
        resolutionPhase: AuthenticationResolutionPhase,
        processScope: AccountSessionScope,
        expected: Bool
    ) {
        #expect(
            AccountSignedOutConfirmation.isConfirmed(
                windowScope: windowScope,
                resolutionPhase: resolutionPhase,
                processScope: processScope
            ) == expected
        )
    }

    @Test
    @MainActor
    func productionCapabilitiesStayExactAndMinimal() {
        #expect(
            AppEnvironment.accountSessionValidationAllowedPaths == [
                "/x/web-interface/nav"
            ]
        )
        #expect(
            AppEnvironment.mainAccountReadAllowedPaths == [
                "/x/player/wbi/playurl",
                "/x/player/wbi/v2",
                "/x/space/wbi/arc/search",
                "/x/v2/dm/wbi/web/seg.so",
                "/x/v2/reply/reply",
                "/x/v2/reply/wbi/main",
                "/x/web-interface/archive/related",
                "/x/web-interface/card",
                "/x/web-interface/history/cursor",
                "/x/web-interface/popular",
                "/x/web-interface/wbi/index/top/feed/rcmd",
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/wbi/view"
            ]
        )
        #expect(
            AppEnvironment.cdnBenchmarkAccountReadAllowedPaths == [
                "/x/player/wbi/playurl",
                "/x/web-interface/wbi/view"
            ]
        )
        #expect(AppEnvironment.watchProgressAccountReadAllowedPaths == nil)
    }

    @Test
    @MainActor
    func everyProductionReadPathCanAuthorizeAnExactGet() async throws {
        let credential = try makeCompositionFixtureCredential()
        let configuredCapabilities = [
            AppEnvironment.accountSessionValidationAllowedPaths,
            AppEnvironment.mainAccountReadAllowedPaths,
            AppEnvironment.cdnBenchmarkAccountReadAllowedPaths
        ]

        for allowedPaths in configuredCapabilities {
            let authorizer = BiliCredentialRequestAuthorizer(
                store: CompositionFixtureCredentialStore(credential: credential),
                allowedPaths: allowedPaths
            )
            for path in allowedPaths {
                let request = HTTPRequest(
                    url: try #require(
                        URL(string: "https://api.bilibili.com\(path)?fixture=1")
                    )
                )

                let authorized = try await authorizer.authorize(request)

                #expect(authorized.url.path == path)
                #expect(authorized.method == .get)
                #expect(authorized.headers == ["Cookie": credential.cookieHeader])
            }
        }
    }
}

private struct CompositionFixtureCredentialStore: WebCredentialStoring {
    let credential: WebCredential

    func load() -> WebCredential? { credential }
    func save(_ credential: WebCredential) {}
    func delete() {}
}

private func makeCompositionFixtureCredential() throws -> WebCredential {
    try WebCredential(
        cookies: WebCredentialCookieName.allCases.map { name in
            WebCredentialCookie(
                name: name,
                value: "FIXTURE_\(name.rawValue)_VALUE",
                domain: ".bilibili.com",
                path: "/",
                isSecure: true,
                isHTTPOnly: name == .session,
                expiresAt: Date(timeIntervalSince1970: 4_102_444_800)
            )
        }
    )
}
