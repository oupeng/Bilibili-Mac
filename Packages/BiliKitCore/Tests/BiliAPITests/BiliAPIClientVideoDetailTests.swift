import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定视频详情契约：走 WBI 签名的 `/wbi/view`，保留分 P 与合集结构并给出稳定的身份，
/// 损坏的合集元素局部降级，简介链接按分段或 `desc` 识别，取消照原样抛出，非法输入在发请求前拒绝。
struct BiliAPIClientVideoDetailTests {
    @Test
    func videoDetailPreservesCurrentPagesAndNestedUGCCollection() async throws {
        let response = jsonResponse(
            #"""
            {"code":0,"data":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"https://images.example.invalid/current.jpg","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":300,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}],"ugc_season":{"id":501,"title":"测试合集","ep_count":3,"sections":[{"season_id":501,"id":601,"title":"第一章","episodes":[{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureA1","cid":900001,"title":"当前视频","arc":{"aid":7001,"bvid":"BV1FixtureA1","title":"当前视频","pic":"https://images.example.invalid/current.jpg","duration":300},"pages":[{"cid":900001,"page":1,"part":"当前 P1","duration":120},{"cid":900002,"page":2,"part":"当前 P2","duration":180}]},{"season_id":501,"section_id":601,"id":702,"aid":7002,"bvid":"BV1FixtureB2","cid":910001,"title":"下一视频","arc":{"duration":200},"page":{"cid":910001,"page":1,"part":"默认 P","duration":200}}]},{"season_id":501,"id":602,"title":"第二章","episodes":[{"season_id":501,"section_id":602,"id":703,"aid":7003,"bvid":"BV1FixtureC3","cid":920001,"title":"第三视频","arc":{"duration":100}}]}]}}}
            """#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.aid == 7_001)
        #expect(detail.pages.map(\.cid) == [900_001, 900_002])
        let collection = try #require(detail.collection)
        #expect(collection.id == 501)
        #expect(collection.sections.count == 2)
        #expect(collection.embeddedEpisodeCount == 3)
        #expect(collection.embeddedCountMatchesReportedCount == true)
        #expect(collection.sections[0].ordinal == 0)
        #expect(collection.sections[1].ordinal == 1)
        #expect(collection.sections[0].episodes[0].knownPages?.map(\.cid) == [900_001, 900_002])
        #expect(collection.sections[0].episodes[1].knownPages == nil)
        #expect(collection.sections[0].episodes[1].defaultCID == 910_001)
    }

    @Test
    func videoDetailPreservesIncompleteCollectionSummary() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"摘要合集","ep_count":20}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let collection = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection
        )

        #expect(collection.sections.isEmpty)
        #expect(collection.reportedEpisodeCount == 20)
        #expect(collection.embeddedCountMatchesReportedCount == false)
    }

    /// 简介按 `desc_v2` 分段拼出：@ 段带上 MID，其余文字按评论正文规则识别网址、BV 号与时间戳。
    @Test
    func videoDetailSummaryLinksMentionsAndDetectedTargets() async throws {
        let segments =
            #"[{"raw_text":"感谢 ","type":1,"biz_id":0},{"raw_text":"合作者","type":2,"biz_id":"20002"},{"raw_text":"参与\n上期 BV1xx411c7mD 1:30 开始 https://www.bilibili.com/video/BV1GJ411x7h7","type":1,"biz_id":0}]"#
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    jsonResponse(
                        #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"旧简介","desc_v2":"#
                            + segments
                            + #","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000}}"#
                    )
                ],
                answersWBINavOnce: true
            )
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(
            detail.summary
                == "感谢 @合作者 参与\n上期 BV1xx411c7mD 1:30 开始 https://www.bilibili.com/video/BV1GJ411x7h7"
        )
        #expect(
            detail.summaryLinks.map(\.target) == [
                .member(CommentAuthor(id: CommentAuthorID(rawValue: "20002"), name: "合作者")),
                .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil),
                .timestamp(seconds: 90),
                .video(bvid: "BV1GJ411x7h7", page: nil, startSeconds: nil)
            ]
        )
        #expect(detail.summaryLinks.first?.range == CommentTextRange(location: 3, length: 4))
    }

    /// 分段缺失、不是数组或有任一段解码失败时退回 `desc`，同样识别其中的链接。
    @Test(arguments: [
        "",
        #","desc_v2":null"#,
        #","desc_v2":"坏数据""#,
        #","desc_v2":[{"raw_text":"片段","type":1},{"type":2,"biz_id":1}]"#
    ])
    func videoDetailSummaryFallsBackToDesc(descV2: String) async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    jsonResponse(
                        #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"见 b23.tv/abc123 和 2:05""#
                            + descV2
                            + #","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000}}"#
                    )
                ],
                answersWBINavOnce: true
            )
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.summary == "见 b23.tv/abc123 和 2:05")
        #expect(detail.summaryLinks.count == 2)
        #expect(detail.summaryLinks.last?.target == .timestamp(seconds: 125))
    }

    /// MID 不合法的 @ 段照样显示为「@昵称 」，只是不生成链接。
    @Test
    func videoDetailSummaryIgnoresMentionsWithoutValidMemberID() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    jsonResponse(
                        #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"","desc_v2":[{"raw_text":"无名","type":2,"biz_id":0},{"raw_text":"@有名","type":2,"biz_id":"--"}],"pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000}}"#
                    )
                ],
                answersWBINavOnce: true
            )
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.summary == "@无名 @有名 ")
        #expect(detail.summaryLinks.isEmpty)
    }

    /// 较早的单 P 视频分 P 标题为空字符串，视频照常解析，标题保留为空。
    @Test
    func videoDetailAcceptsAnEmptyPageTitle() async throws {
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    jsonResponse(
                        #"{"code":0,"data":{"aid":8996792,"bvid":"BV1Fx411C7Ne","title":"较早的视频","desc":"","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":988,"pubdate":1488737993,"pages":[{"cid":14854734,"page":1,"part":"","duration":988}]}}"#
                    )
                ],
                answersWBINavOnce: true
            )
        )

        let detail = try await client.videoDetail(for: "BV1Fx411C7Ne")

        #expect(detail.pages.map(\.cid) == [14_854_734])
        #expect(detail.pages.first?.title == "")
    }

    @Test
    func videoDetailRejectsDuplicatePageIdentity() async throws {
        let pages =
            #"[{"cid":900001,"page":1,"part":"P1","duration":60},{"cid":900001,"page":2,"part":"P2","duration":60}]"#
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    jsonResponse(
                        #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":"#
                            + pages + "}}"
                    )
                ],
                answersWBINavOnce: true
            )
        )

        await #expect(throws: BiliAPIError.decodingFailed) {
            try await client.videoDetail(for: "BV1FixtureA1")
        }
    }

    @Test
    func malformedCollectionEpisodeDoesNotBlockCurrentVideo() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","ep_count":1,"sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":999,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":910001,"title":"","arc":{"aid":7002,"bvid":"BV1FixtureC3","duration":100},"page":{"cid":910002,"page":1,"part":"P1","duration":100}}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let detail = try await client.videoDetail(for: "BV1FixtureA1")

        #expect(detail.pages.map(\.cid) == [900_001])
        let episode = try #require(detail.collection?.sections.first?.episodes.first)
        #expect(!episode.isIdentityConsistent)
        #expect(episode.bvid == nil)
        #expect(episode.defaultCID == nil)
    }

    @Test
    func malformedCollectionElementsPreserveValidOccurrences() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureB2","title":"一"},null,{"season_id":501,"section_id":601,"id":702,"bvid":"BV1FixtureC3","title":"二"}]},null]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let collection = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection
        )

        #expect(collection.sections.count == 2)
        #expect(collection.sections[0].episodes.count == 3)
        #expect(collection.sections[0].episodes[0].isIdentityConsistent)
        #expect(!collection.sections[0].episodes[1].isIdentityConsistent)
        #expect(collection.sections[0].episodes[2].isIdentityConsistent)
        #expect(!collection.sections[1].isIdentityConsistent)
    }

    @Test
    func duplicateSectionOccurrencesKeepEpisodeIdentitiesDistinct() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"section_id":601,"episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureB2","title":"一"}]},{"season_id":501,"id":601,"episodes":[{"season_id":501,"section_id":601,"id":701,"bvid":"BV1FixtureC3","title":"二"}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let sections = try #require(
            try await client.videoDetail(for: "BV1FixtureA1").collection?.sections
        )
        let first = try #require(sections[0].episodes.first)
        let second = try #require(sections[1].episodes.first)

        #expect(sections[0].id.occurrenceOrdinal == 0)
        #expect(sections[1].id.occurrenceOrdinal == 1)
        #expect(first.id != second.id)
        #expect(first.id.sectionOccurrenceOrdinal == 0)
        #expect(second.id.sectionOccurrenceOrdinal == 1)
    }

    @Test
    func conflictingSectionIDAliasesAreRetainedAsInvalid() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"section_id":602,"episodes":[]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let section = try #require(
            try await client.videoDetail(for: "BV1FixtureA1")
                .collection?.sections.first
        )

        #expect(!section.isIdentityConsistent)
    }

    @Test
    func collectionIdentityRemainsStableWhenOrderChanges() async throws {
        func response(order: String) -> HTTPResponse {
            jsonResponse(
                #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","ep_count":2,"sections":[{"season_id":501,"id":601,"title":"分部","episodes":ORDER}]}}}"#
                    .replacingOccurrences(
                        of: "ORDER",
                        with: order
                    )
            )
        }
        let firstEpisode =
            #"{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":910001,"title":"一"}"#
        let secondEpisode =
            #"{"season_id":501,"section_id":601,"id":702,"aid":7002,"bvid":"BV1FixtureC3","cid":920001,"title":"二"}"#
        let client = BiliAPIClient(
            transport: StubTransport(
                responses: [
                    response(order: "[\(firstEpisode),\(secondEpisode)]"),
                    response(order: "[\(secondEpisode),\(firstEpisode)]")
                ],
                answersWBINavOnce: true
            )
        )

        let first = try await client.videoDetail(for: "BV1FixtureA1")
        let second = try await client.videoDetail(for: "BV1FixtureA1")
        let firstIDs = try #require(first.collection?.sections.first?.episodes.map(\.id))
        let secondIDs = try #require(second.collection?.sections.first?.episodes.map(\.id))

        #expect(firstIDs == secondIDs.reversed())
        #expect(firstIDs[0].occurrenceOrdinal == nil)
    }

    @Test
    func episodePagesAreSortedAndDefaultCIDMustBelongToThem() async throws {
        let response = jsonResponse(
            #"{"code":0,"data":{"bvid":"BV1FixtureA1","title":"当前视频","desc":"说明","pic":"","owner":{"mid":10001,"name":"作者"},"stat":{"view":1,"danmaku":2,"like":3},"duration":120,"pubdate":1720000000,"pages":[{"cid":900001,"page":1,"part":"P1","duration":120}],"ugc_season":{"id":501,"title":"合集","sections":[{"season_id":501,"id":601,"title":"分部","episodes":[{"season_id":501,"section_id":601,"id":701,"aid":7001,"bvid":"BV1FixtureB2","cid":999999,"title":"视频","pages":[{"cid":910002,"page":2,"part":"P2","duration":50},{"cid":910001,"page":1,"part":"P1","duration":50}]}]}]}}}"#
        )
        let client = BiliAPIClient(
            transport: StubTransport(responses: [response], answersWBINavOnce: true)
        )

        let episode = try #require(
            try await client.videoDetail(for: "BV1FixtureA1")
                .collection?.sections.first?.episodes.first
        )

        #expect(episode.knownPages?.map(\.index) == [1, 2])
        #expect(episode.defaultCID == nil)
        #expect(!episode.isIdentityConsistent)
    }

    /// 视频详情走 WBI 签名的 `/wbi/view`：未签名的 `/view` 对游客返回 412。
    @Test
    func videoDetailUsesTheSignedWBIEndpoint() async throws {
        let transport = StubTransport(
            responses: [try fixtureResponse("view")],
            answersWBINavOnce: true
        )
        let client = BiliAPIClient(transport: transport, timestampProvider: { 1_700_000_000 })

        _ = try await client.videoDetail(for: "BV1FixtureA1")

        let request = try #require(transport.capturedRequests().last)
        #expect(request.url.path == "/x/web-interface/wbi/view")
        let queryItems = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(queryItems?.contains(URLQueryItem(name: "bvid", value: "BV1FixtureA1")) == true)
        #expect(queryItems?.contains(URLQueryItem(name: "wts", value: "1700000000")) == true)
        #expect(queryItems?.first { $0.name == "w_rid" }?.value?.count == 32)
    }

    @Test
    func cancellationIsNotCollapsedIntoTransportFailure() async {
        let client = BiliAPIClient(transport: StubTransport([.cancellation]))

        await #expect(throws: CancellationError.self) {
            try await client.videoDetail(for: "BV1FixtureA1")
        }
    }

    @Test
    func validatesInputBeforeSendingRequest() async {
        let transport = StubTransport(responses: [])
        let client = BiliAPIClient(transport: transport)

        await #expect(throws: BiliAPIError.invalidRequest) {
            try await client.videoDetail(for: "not-a-bvid")
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
