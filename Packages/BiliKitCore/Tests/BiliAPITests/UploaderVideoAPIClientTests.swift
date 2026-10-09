import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

struct UploaderVideoAPIClientTests {
    @Test
    func pageMapsFieldsAndDropsInvalidEntries() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [try fixtureResponse("nav"), try fixtureResponse("uploader-videos")]
            ),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)

        #expect(page.videos.map(\.bvid) == ["BV1FixtureA1", "BV1FixtureB2"])
        #expect(page.pageNumber == 1)
        #expect(page.pageSize == 30)
        #expect(page.totalCount == 61)
        #expect(page.hasMore)

        let first = page.videos[0]
        #expect(first.title == "投稿 & 一")
        #expect(first.coverURL?.absoluteString == "https://images.example.invalid/a.jpg")
        #expect(first.durationSeconds == 754)
        #expect(first.viewCount == 12_345)
        #expect(first.danmakuCount == 678)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_720_000_000))
        #expect(!first.isCollaboration)

        // 隐藏的统计（"--"）不当作 0；协议相对封面地址补成 https。
        let second = page.videos[1]
        #expect(second.coverURL?.absoluteString == "https://images.example.invalid/b.jpg")
        #expect(second.durationSeconds == 3_723)
        #expect(second.viewCount == nil)
        #expect(second.danmakuCount == nil)
        #expect(second.isCollaboration)
    }

    @Test(arguments: [
        (UploaderVideoOrder.newest, "pubdate"),
        (.mostPlayed, "click"),
        (.mostFavorited, "stow")
    ])
    func requestIsSignedAccountReadWithSpaceReferer(
        order: UploaderVideoOrder,
        apiValue: String
    ) async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("nav"), try fixtureResponse("uploader-videos")]
        )
        let client = BiliAPIClient(
            transport: transport,
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await client.uploaderVideos(ownerID: 10_001, order: order, page: 2)

        let requests = transport.capturedRequests()
        #expect(requests.map(\.url.path) == ["/x/web-interface/nav", "/x/space/wbi/arc/search"])
        let request = try #require(requests.last)
        #expect(request.headers["Referer"] == "https://space.bilibili.com/10001/")
        #expect(request.headers["Cookie"] == StubAuthorizer.cookie)
        let query = Dictionary(
            uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        #expect(query["mid"] == "10001")
        #expect(query["pn"] == "2")
        #expect(query["ps"] == "30")
        #expect(query["order"] == apiValue)
        #expect(query["wts"] == "1700000000")
        #expect(query["w_rid"]?.count == 32)
    }

    @Test
    func lastPageReportsNoMore() async throws {
        let body = #"""
            {"code":0,"data":{"list":{"vlist":[{"bvid":"BV1FixtureC3","title":"最后一条","pic":"","length":"00:30","play":1,"video_review":0,"created":1700000000}]},"page":{"count":61}}}
            """#
        let client = BiliAPIClient(
            transport: StubTransport(responses: [try fixtureResponse("nav"), jsonResponse(body)]),
            requestAuthorizer: StubAuthorizer(),
            timestampProvider: { 1_700_000_000 }
        )

        let page = try await client.uploaderVideos(ownerID: 10_001, order: .newest, page: 3)

        #expect(page.videos.map(\.bvid) == ["BV1FixtureC3"])
        #expect(!page.hasMore)
    }

    @Test
    func missingCredentialFailsWithoutAnonymousRequest() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("nav"), try fixtureResponse("uploader-videos")]
        )
        let repository = BiliContentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(.missingCredential)),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: ContentApplicationError.authenticationInvalid) {
            try await repository.uploaderVideos(ownerID: 10_001, order: .newest, page: 1)
        }
        #expect(
            !transport.capturedRequests().contains { $0.url.path == "/x/space/wbi/arc/search" }
        )
    }

    @Test(arguments: [(Int64(0), 1), (10_001, 0)])
    func invalidRequestSendsNothing(ownerID: Int64, page: Int) async throws {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport, requestAuthorizer: StubAuthorizer())

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.uploaderVideos(ownerID: ownerID, order: .newest, page: page)
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test(
        arguments: [
            ("12:34", 754),
            ("1:02:03", 3_723),
            ("00:00", 0),
            ("5", nil),
            ("a:b", nil),
            (":30", nil),
            ("-1:00", nil),
            ("1:2:3:4", nil)
        ] as [(String, Int?)]
    )
    func clockDurationParsing(value: String, expected: Int?) {
        #expect(UploaderVideoItemPayload.seconds(fromClock: value) == expected)
    }
}
