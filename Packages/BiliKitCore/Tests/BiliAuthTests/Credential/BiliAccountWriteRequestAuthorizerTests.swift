import BiliNetworking
import Foundation
import Testing

@testable import BiliAuth

/// 账户写入授权器只放行 schema 表里精确形状的 POST，绑定预期账户，只注入 `SESSDATA` 与表单 csrf。
@Suite(.timeLimit(.minutes(1)))
struct BiliAccountWriteRequestAuthorizerTests {
    private static let addPath = "/x/v2/history/toview/add"
    private static let removePath = "/x/v2/history/toview/del"
    private static let accountID = "42"

    @Test(arguments: [
        (addPath, "https://www.bilibili.com/"),
        (removePath, "https://www.bilibili.com/watchlater/")
    ])
    func authorizesExactContractAndInjectsOnlySessionAndCSRF(
        path: String,
        referer: String
    ) async throws {
        let authorizer = try makeAuthorizer()

        let authorized = try await authorizer.authorize(
            try writeRequest(path: path, referer: referer),
            boundTo: Self.accountID
        )

        #expect(authorized.headers["Cookie"] == "SESSDATA=FIXTURE_SESSDATA_VALUE")
        #expect(authorized.headers["Origin"] == "https://www.bilibili.com")
        #expect(authorized.method == .post)
        let body = try #require(authorized.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body == "aid=170001&csrf=FIXTURE_bili_jct_VALUE")
    }

    @Test
    func rejectsTargetMethodAndPathExpansion() async throws {
        let authorizer = try makeAuthorizer()
        let path = Self.addPath
        let cases: [(String, HTTPMethod)] = [
            ("http://api.bilibili.com\(path)", .post),
            ("https://api.bilibili.com.evil.invalid\(path)", .post),
            ("https://api.bilibili.com:444\(path)", .post),
            ("https://user@api.bilibili.com\(path)", .post),
            ("https://api.bilibili.com\(path)?aid=170001", .post),
            ("https://api.bilibili.com\(path)#fragment", .post),
            ("https://api.bilibili.com/x/v2/history/toview/clear", .post),
            ("https://api.bilibili.com/x/click-interface/web/heartbeat", .post),
            ("https://api.bilibili.com\(path)", .get)
        ]
        for (urlString, method) in cases {
            let request = HTTPRequest(
                url: try #require(URL(string: urlString)),
                method: method,
                headers: validHeaders(referer: "https://www.bilibili.com/"),
                body: Data("aid=170001".utf8)
            )
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(request, boundTo: Self.accountID)
            }
        }
    }

    /// Composition 没有放行的 path 即使在 schema 表里也不授权。
    @Test
    func rejectsSchemaPathOutsideTheAllowlist() async throws {
        let authorizer = try makeAuthorizer(allowedPaths: [Self.addPath])

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(
                    path: Self.removePath,
                    referer: "https://www.bilibili.com/watchlater/"
                ),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["X-Unapproved", "Cookie", "Authorization", "X-CSRF-Token"])
    func rejectsHeaderExpansionAndCallerCredentials(header: String) async throws {
        let authorizer = try makeAuthorizer()
        var headers = validHeaders(referer: "https://www.bilibili.com/")
        headers[header] = "FIXTURE_PREEXISTING_VALUE"

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath, headers: headers),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["Origin", "Referer", "User-Agent", "Content-Type", "Accept"])
    func rejectsMissingOrAlteredFixedHeaders(header: String) async throws {
        let authorizer = try makeAuthorizer()
        var missing = validHeaders(referer: "https://www.bilibili.com/")
        missing[header] = nil
        var altered = validHeaders(referer: "https://www.bilibili.com/")
        altered[header] = "https://www.bilibili.com/video/BV17x411w7KC/"

        for headers in [missing, altered] {
            await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
                try await authorizer.authorize(
                    try writeRequest(path: Self.addPath, headers: headers),
                    boundTo: Self.accountID
                )
            }
        }
    }

    /// 每个 path 只认自己的固定 Referer。
    @Test
    func rejectsTheOtherPathsReferer() async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(
                    path: Self.removePath,
                    referer: "https://www.bilibili.com/"
                ),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: [
        "aid=170001&csrf=PRESET",
        "aid=170001&csrf_token=PRESET",
        "aid=170001&viewed=true",
        "aid=170001&aid=170001",
        "aid=0",
        "aid=-3",
        "aid=17x",
        "aid=",
        "bvid=BV17x411w7KC",
        "",
        "aid=" + String(repeating: "1", count: 1_100)
    ])
    func rejectsBodiesOutsideTheSchema(body: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath, body: body),
                boundTo: Self.accountID
            )
        }
    }

    @Test(arguments: ["", "0", "-42", "42a", "FIXTURE"])
    func rejectsMalformedExpectedAccount(subject: String) async throws {
        let authorizer = try makeAuthorizer()

        await #expect(throws: BiliRequestAuthorizationError.requestNotAllowed) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath),
                boundTo: subject
            )
        }
    }

    /// 凭据属于另一个账户时按凭据失效拒绝，但不删除：那可能是另一窗口刚登录的账户。
    @Test
    func rejectsCredentialOfAnotherAccountWithoutDeletingIt() async throws {
        let store = MemoryWebCredentialStore(credential: try makeFixtureCredential(userID: "7"))
        let authorizer = BiliAccountWriteRequestAuthorizer(
            store: store,
            allowedPaths: Set(BiliAccountWriteRequestAuthorizer.schemas.keys)
        )

        await #expect(throws: BiliRequestAuthorizationError.accountMismatch) {
            try await authorizer.authorize(
                try writeRequest(path: Self.addPath),
                boundTo: Self.accountID
            )
        }
        #expect(
            BiliRequestAuthorizationError.accountMismatch.authorizationFailureKind
                == .invalidCredential
        )
        #expect(store.deleteCount == 0)
    }

    @Test
    func missingCorruptOrExpiredCredentialCannotAuthorize() async throws {
        let missing = BiliAccountWriteRequestAuthorizer(
            store: MemoryWebCredentialStore(),
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.missingCredential) {
            try await missing.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }

        let corruptStore = MemoryWebCredentialStore(
            loadError: WebCredentialStoreError.corruptCredential
        )
        let corrupt = BiliAccountWriteRequestAuthorizer(
            store: corruptStore,
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.invalidCredential) {
            try await corrupt.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
        #expect(corruptStore.deleteCount == 1)

        let expiredStore = MemoryWebCredentialStore(
            credential: try makeFixtureCredential(expiresAt: .distantPast, userID: "42")
        )
        let expired = BiliAccountWriteRequestAuthorizer(
            store: expiredStore,
            allowedPaths: [Self.addPath]
        )
        await #expect(throws: BiliRequestAuthorizationError.expiredCredential) {
            try await expired.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
        #expect(expiredStore.deleteCount == 1)
    }

    /// 写请求不读「已确认未登录」：Keychain 不可用一律失败关闭。
    @Test
    func unavailableKeychainFailsClosed() async throws {
        let authorizer = BiliAccountWriteRequestAuthorizer(
            store: MemoryWebCredentialStore(loadError: StubAuthError.storeUnavailable),
            allowedPaths: [Self.addPath]
        )

        await #expect(throws: BiliRequestAuthorizationError.credentialStoreUnavailable) {
            try await authorizer.authorize(try writeRequest(path: Self.addPath), boundTo: "42")
        }
    }

    private func makeAuthorizer(
        allowedPaths: Set<String> = [addPath, removePath]
    ) throws -> BiliAccountWriteRequestAuthorizer {
        BiliAccountWriteRequestAuthorizer(
            store: MemoryWebCredentialStore(
                credential: try makeFixtureCredential(userID: Self.accountID)
            ),
            allowedPaths: allowedPaths
        )
    }

    private func validHeaders(referer: String) -> [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded",
            "Origin": "https://www.bilibili.com",
            "Referer": referer,
            "User-Agent": HTTPUserAgent.browserCompatible
        ]
    }

    private func writeRequest(
        path: String,
        referer: String = "https://www.bilibili.com/",
        headers: [String: String]? = nil,
        body: String = "aid=170001"
    ) throws -> HTTPRequest {
        HTTPRequest(
            url: try #require(URL(string: "https://api.bilibili.com\(path)")),
            method: .post,
            headers: headers ?? validHeaders(referer: referer),
            body: Data(body.utf8)
        )
    }
}
