import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

/// 固定稍后再看写入契约：BV 号在本地换成 aid，表单只有 aid，固定 header 带 Origin，经账户写授权器绑定窗口账户；
/// 远端与授权失败映射为 `AccountWriteError`；认证会话失效后不发出、也不报告旧会话的写入。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientAccountWriteTests {
    @Test(arguments: [
        (true, "/x/v2/history/toview/add", "https://www.bilibili.com/"),
        (false, "/x/v2/history/toview/del", "https://www.bilibili.com/watchlater/")
    ])
    func buildsExactWatchLaterWrite(adds: Bool, path: String, referer: String) async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliWatchLaterWriteRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))

        if adds {
            try await repository.add(target, accountID: 42)
        } else {
            try await repository.remove(target, accountID: 42)
        }

        let request = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.bilibili.com\(path)")
        #expect(
            request.headers == [
                "Accept": "application/json",
                "Content-Type": "application/x-www-form-urlencoded",
                "Origin": "https://www.bilibili.com",
                "Referer": referer,
                "User-Agent": HTTPUserAgent.browserCompatible
            ]
        )
        #expect(request.body == Data("aid=170001".utf8))
        #expect(transport.capturedRequests().count == 1)
    }

    @Test(arguments: [
        (200, -101, AccountWriteError.authenticationInvalid),
        (200, -111, .authenticationInvalid),
        (403, 0, .restricted),
        (412, 0, .restricted),
        (200, -352, .restricted),
        (200, 90_001, .listFull),
        (200, 90_003, .contentUnavailable),
        (200, -404, .contentUnavailable),
        (200, 12_345, .rejected(code: 12_345)),
        (500, 0, .unavailable)
    ])
    func mapsRemoteFailure(status: Int, code: Int, expected: AccountWriteError) async throws {
        let repository = BiliWatchLaterWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code, status: status)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )

        await #expect(throws: expected) {
            try await repository.add(try #require(VideoWriteTarget(bvid: "BV17x411w7KC")), accountID: 42)
        }
    }

    @Test
    func htmlRiskControlPageIsRestricted() async throws {
        let repository = BiliWatchLaterWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [htmlRiskControlResponse()]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )

        await #expect(throws: AccountWriteError.restricted) {
            try await repository.remove(
                try #require(VideoWriteTarget(bvid: "BV17x411w7KC")),
                accountID: 42
            )
        }
    }

    /// 凭据失效（含账户不符）、已登录却无凭据、Keychain 不可用与授权器拒绝各有自己的写入错误，都不发出请求。
    @Test(arguments: [
        (HTTPRequestAuthorizationFailureKind.invalidCredential, AccountWriteError.authenticationInvalid),
        (.missingCredential, .authenticationRequired),
        (.unavailable, .authenticationUnavailable),
        (.denied, .invalidRequest)
    ])
    func mapsAuthorizationFailure(
        kind: HTTPRequestAuthorizationFailureKind,
        expected: AccountWriteError
    ) async throws {
        let transport = StubTransport(responses: [])
        let repository = BiliWatchLaterWriteRepository(
            client: BiliAPIClient(
                transport: transport,
                accountWriteAuthorizer: StubSubjectBoundAuthorizer(.fail(kind))
            )
        )

        await #expect(throws: expected) {
            try await repository.add(try #require(VideoWriteTarget(bvid: "BV17x411w7KC")), accountID: 42)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    /// 没有账户写授权器的 client（测速、观看进度 writer）与无法换算 aid 的 BV 号都在发请求前失败。
    @Test
    func refusesWithoutWriteAuthorizerOrConvertibleBVID() async throws {
        let transport = StubTransport(responses: [])
        let unauthorized = BiliWatchLaterWriteRepository(
            client: BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())
        )
        await #expect(throws: AccountWriteError.authenticationRequired) {
            try await unauthorized.add(try #require(VideoWriteTarget(bvid: "BV17x411w7KC")), accountID: 42)
        }

        let authorizer = StubSubjectBoundAuthorizer()
        let client = BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.addToWatchLater(bvid: "BV1FixtureA1x", accountID: 42)
        }
        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.addToWatchLater(bvid: "BV17x411w7KC", accountID: 0)
        }
        #expect(await authorizer.subjects.isEmpty)
        #expect(transport.capturedRequests().isEmpty)
    }

    /// 授权期间认证会话失效（登出、换号、凭据失效）：写入按取消结束，旧会话的请求不发出。
    @Test
    func writeCannotCrossSessionInvalidationBoundary() async throws {
        let authorizer = StubSubjectBoundAuthorizer(suspendingCall: 1)
        let firstTransport = StubTransport(responses: [statusResponse(code: 0)])
        let replacementTransport = StubTransport(responses: [statusResponse(code: 0)])
        let transportFactory = SequentialTransportFactory(
            transports: [firstTransport, replacementTransport]
        )
        let client = BiliAPIClient(
            accountWriteAuthorizer: authorizer,
            transportFactory: { transportFactory.makeTransport() }
        )

        let write = Task {
            try await client.removeFromWatchLater(bvid: "BV17x411w7KC", accountID: 42)
        }
        await authorizer.waitUntilSuspended()
        await client.invalidateAuthenticatedSession()
        await authorizer.resume()

        await #expect(throws: CancellationError.self) {
            try await write.value
        }
        #expect(firstTransport.capturedRequests().isEmpty)
        #expect(replacementTransport.capturedRequests().isEmpty)
    }

    private func statusResponse(code: Int, status: Int = 200) -> HTTPResponse {
        jsonResponse("{\"code\":\(code),\"message\":\"fixture\",\"ttl\":1}", statusCode: status)
    }
}
