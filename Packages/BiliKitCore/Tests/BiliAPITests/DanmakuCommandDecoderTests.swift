import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import SwiftProtobuf
import Testing

@testable import BiliAPI

/// 互动弹幕的契约：`dm/web/view` 不签 WBI、只带 type 与 cid；第一版只认 UP 主弹幕、评分与投票，其余类型与不合规的
/// 单条跳过；卡片的时长与位置越界时取默认值；条数超限或 protobuf 解不开时整份失败。
@Suite(.timeLimit(.minutes(1)))
struct DanmakuCommandDecoderTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1DanmakuFixture", cid: 700_001)

    @Test
    func requestIsUnsignedAndCarriesOnlyTypeAndCid() async throws {
        let transport = StubTransport(responses: [try protobufResponse([])])
        let repository = BiliDanmakuRepository(
            client: BiliAPIClient(transport: transport, timestampProvider: { 1_700_000_000 })
        )

        let commands = try await repository.commands(for: identity)

        #expect(commands == .empty)
        let request = try #require(transport.capturedRequests().first)
        #expect(request.url.path == "/x/v2/dm/web/view")
        let query = try #require(
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
        )
        #expect(Set(query.map(\.name)) == ["type", "oid"])
        #expect(query.first { $0.name == "oid" }?.value == "700001")
        #expect(request.headers["Accept"] == "application/octet-stream")
        #expect(request.headers["Cookie"] == nil)
    }

    @Test
    func decodesUploaderGradeAndVoteAndSkipsOtherKinds() throws {
        let commands = try DanmakuCommandDecoder.commands(
            from: payload([
                element(id: 1, command: "#UP#", content: " 感谢三连 ", progress: 12_000),
                element(
                    id: 2,
                    command: "#GRADE#",
                    content: "fallback",
                    progress: 1_300,
                    extra:
                        #"{"msg":"始皇未解之谜！","avg_score":9.9,"count":8029,"mid_score":4,"#
                        + #""duration":5000,"posX_2":50,"posY_2":65}"#
                ),
                element(
                    id: 3,
                    command: "#VOTE#",
                    content: "投票弹幕",
                    progress: 13_400,
                    extra:
                        #"{"question":"为何没人起疑？","cnt":11711,"my_vote":2,"duration":7000,"#
                        + #""posX_2":97,"posY_2":85,"options":[{"idx":1,"desc":"古人不洗澡","#
                        + #""cnt":2737},{"idx":2,"desc":"咸鱼太香了","cnt":4930}]}"#
                ),
                element(
                    id: 4,
                    command: "#ATTENTION#",
                    content: "关注弹幕",
                    progress: 20_000,
                    extra: "{}"
                ),
                element(id: 5, command: "#LINK#", content: "视频", progress: 30_000, extra: "{}")
            ])
        )

        let uploader = try #require(commands.uploaderEvents.first)
        #expect(commands.uploaderEvents.count == 1)
        #expect(uploader.id == "command:1")
        #expect(uploader.text == "感谢三连")
        #expect(uploader.timeSeconds == 12)
        #expect(uploader.isUploader)
        #expect(uploader.mode == .scrolling)

        #expect(commands.cards.map(\.id) == ["command:2", "command:3"])
        let grade = try #require(commands.cards.first)
        #expect(grade.timeSeconds == 1.3)
        #expect(grade.durationSeconds == 5)
        #expect(grade.position == DanmakuCardPosition(x: 0.5, y: 0.65))
        #expect(
            grade.content
                == .grade(
                    DanmakuGradeCard(
                        title: "始皇未解之谜！",
                        averageScore: 9.9,
                        participantCount: 8029,
                        myScore: 4
                    )
                )
        )
        let vote = try #require(commands.cards.last)
        #expect(vote.durationSeconds == 7)
        #expect(
            vote.content
                == .vote(
                    DanmakuVoteCard(
                        question: "为何没人起疑？",
                        options: [
                            DanmakuVoteOption(text: "古人不洗澡", voteCount: 2737),
                            DanmakuVoteOption(text: "咸鱼太香了", voteCount: 4930)
                        ],
                        participantCount: 11711,
                        myOptionIndex: 1
                    )
                )
        )
        #expect(vote.description == "DanmakuCommandCard(redacted)")
    }

    /// 单条不合规只跳过这一条；时长、位置越界或缺失时取默认值，没投过、没评过为 nil。
    @Test
    func malformedEntriesAreSkippedAndOutOfRangeLayoutFallsBack() throws {
        let commands = try DanmakuCommandDecoder.commands(
            from: payload([
                element(
                    id: 1,
                    command: "#GRADE#",
                    content: "x",
                    progress: 1_000,
                    extra: #"{"msg":"a","avg_score":11,"count":1}"#
                ),
                element(
                    id: 2,
                    command: "#VOTE#",
                    content: "x",
                    progress: 1_000,
                    extra: #"{"question":"q","cnt":0,"options":[]}"#
                ),
                element(
                    id: 3,
                    command: "#GRADE#",
                    content: "x",
                    progress: 1_000,
                    extra: "not json"
                ),
                element(id: 4, command: "#UP#", content: "   ", progress: 1_000),
                element(id: 5, command: "#UP#", content: "ok", progress: -1),
                element(
                    id: 6,
                    command: "#GRADE#",
                    content: "评分",
                    progress: 2_000,
                    extra:
                        #"{"avg_score":"9","count":3,"mid_score":0,"duration":999999,"#
                        + #""posX_2":150}"#
                ),
                element(
                    id: 7,
                    command: "#GRADE#",
                    content: "评分",
                    progress: 3_000,
                    extra:
                        #"{"avg_score":8,"count":3,"mid_score":0,"duration":999999,"posX_2":150}"#
                )
            ])
        )

        #expect(commands.uploaderEvents.isEmpty)
        let card = try #require(commands.cards.first)
        #expect(commands.cards.count == 1)
        #expect(card.id == "command:7")
        #expect(card.durationSeconds == 5)
        #expect(card.position == DanmakuCardPosition(x: 0.5, y: 0.65))
        #expect(
            card.content
                == .grade(
                    DanmakuGradeCard(
                        title: "评分",
                        averageScore: 8,
                        participantCount: 3,
                        myScore: nil
                    )
                )
        )
    }

    @Test
    func tooManyEntriesOrUndecodableBodiesFailTheWholeResponse() throws {
        let many = (0..<201).map {
            element(id: Int64($0 + 1), command: "#UP#", content: "x", progress: 0)
        }
        #expect(throws: BiliAPIError.invalidDanmakuData) {
            try DanmakuCommandDecoder.commands(from: payload(many))
        }
        #expect(throws: BiliAPIError.invalidDanmakuData) {
            try DanmakuCommandDecoder.commands(from: Data([0xFF, 0xFF, 0xFF]))
        }
    }

    private func element(
        id: Int64,
        command: String,
        content: String,
        progress: Int32,
        extra: String = ""
    ) -> Bilikit_Danmaku_CommandElement {
        var element = Bilikit_Danmaku_CommandElement()
        element.id = id
        element.command = command
        element.content = content
        element.progressMilliseconds = progress
        element.extra = extra
        return element
    }

    private func payload(_ elements: [Bilikit_Danmaku_CommandElement]) throws -> Data {
        var reply = Bilikit_Danmaku_ViewReply()
        reply.commandElements = elements
        return try reply.serializedData()
    }

    private func protobufResponse(
        _ elements: [Bilikit_Danmaku_CommandElement]
    ) throws -> HTTPResponse {
        // 空回复序列化为 0 字节，会被当作空正文拒绝；这里补一个空的字段 9，等价于没有互动弹幕的真实响应。
        var body = try payload(elements)
        if body.isEmpty { body = Data([0x4A, 0x00]) }
        return HTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/octet-stream"],
            body: body
        )
    }
}
