import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定收藏写入契约：归属改动一次请求带单个视频与两侧夹 id（空的一侧发空串），夹内移除只带一个 `<aid>:2` 条目，
/// 都经账户写授权器绑定窗口账户；收藏专属业务码映射为对应的写入错误；归属读取与列表同一请求，另带 `type=2` 与 `rid`，
/// 缺 `fav_state` 时整份失败。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientFavoriteWriteTests {
    @Test
    func membershipUpdateSendsOneVideoAndBothSides() async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliFavoritesWriteRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        let change = try #require(
            FavoriteMembershipChange(target: target, adding: [12, 11], removing: [])
        )

        try await repository.update(change, accountID: 42)

        let request = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(request.url.absoluteString == "https://api.bilibili.com/x/v3/fav/resource/deal")
        #expect(request.headers["Referer"] == "https://www.bilibili.com/")
        #expect(request.headers["Origin"] == "https://www.bilibili.com")
        #expect(
            formFields(request) == [
                "rid": "170001", "type": "2", "add_media_ids": "11,12", "del_media_ids": "",
                "platform": "web"
            ]
        )
    }

    @Test
    func folderEntryRemovalSendsASingleVideoResource() async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliFavoritesWriteRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )

        try await repository.remove(
            try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001)),
            accountID: 42
        )

        let request = try #require(await authorizer.capturedRequests().last)
        #expect(
            request.url.absoluteString == "https://api.bilibili.com/x/v3/fav/resource/batch-del"
        )
        #expect(
            formFields(request) == ["resources": "170001:2", "media_id": "10", "platform": "web"]
        )
    }

    @Test(arguments: [
        (11_203, AccountWriteError.listFull),
        (11_010, .contentUnavailable),
        (11_201, .rejected(code: 11_201)),
        (90_001, .rejected(code: 90_001)),
        (-101, .authenticationInvalid)
    ])
    func mapsFavoriteBusinessCodes(code: Int, expected: AccountWriteError) async throws {
        let repository = BiliFavoritesWriteRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: code)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )

        await #expect(throws: expected) {
            try await repository.remove(
                try #require(FavoriteFolderEntry(folderID: 10, videoAID: 170_001)),
                accountID: 42
            )
        }
    }

    /// 没有改动、两侧相交或 BV 号不合法的归属改动不发出请求。
    @Test(
        arguments: [
            ([], []),
            ([11], [11]),
            ([0], [])
        ] as [([Int64], [Int64])]
    )
    func invalidMembershipUpdatesSendNothing(adding: [Int64], removing: [Int64]) async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(
            transport: transport,
            accountWriteAuthorizer: StubSubjectBoundAuthorizer()
        )

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.updateFavoriteMembership(
                bvid: "BV17x411w7KC",
                adding: adding,
                removing: removing,
                accountID: 42
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func membershipReadAddsTheVideoToTheFolderListRequest() async throws {
        let transport = StubTransport(responses: [try fixtureResponse("favorite-folders")])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        let memberships = try await client.favoriteFolderMemberships(
            ownerID: 10_001,
            bvid: "BV17x411w7KC"
        )

        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/v3/fav/folder/created/list-all")
        #expect(queryFields(request) == ["up_mid": "10001", "type": "2", "rid": "170001"])
        #expect(memberships.map(\.id) == [3001, 3002, 3003])
        #expect(memberships.allSatisfy { !$0.containsVideo })
    }

    /// 不知道归属就给不出勾选的初始状态：保留下来的行缺 `fav_state` 或取值异常时整份失败。
    @Test(arguments: [
        #"{"code":0,"data":{"list":[{"id":3001,"attr":0,"title":"默认","fav_state":1},{"id":3002,"attr":2,"title":"甲"}]}}"#,
        #"{"code":0,"data":{"list":[{"id":3001,"attr":0,"title":"默认","fav_state":2}]}}"#
    ])
    func membershipReadFailsWithoutAKnownState(body: String) async {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer()
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.favoriteFolderMemberships(ownerID: 10_001, bvid: "BV17x411w7KC")
        }
    }

    /// 只有视频条目（type 2，含失效的）带 av 号，可以从夹内移除；合集、音频、番剧与未知类型没有。
    @Test
    func onlyVideoEntriesCarryTheirAID() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try fixtureResponse("favorite-resources")]),
            requestAuthorizer: StubAuthorizer()
        )

        let page = try await client.favoriteFolderPage(
            request: FavoriteFolderRequest(folderID: 3001)
        )

        #expect(
            page.items.map(\.videoAID) == [
                10_001, 10_002, 10_003, 10_004, nil, nil, nil, nil, 10_007, nil
            ]
        )
    }

    private func formFields(_ request: HTTPRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = request.body.flatMap { String(data: $0, encoding: .utf8) }
        return fields(components.queryItems)
    }

    private func queryFields(_ request: HTTPRequest) -> [String: String] {
        fields(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    private func fields(_ items: [URLQueryItem]?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (items ?? []).map { ($0.name, $0.value ?? "") })
    }
}
