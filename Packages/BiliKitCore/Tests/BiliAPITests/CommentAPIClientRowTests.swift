import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论页的行映射契约：置顶回复保持服务端顺序，增强字段与回复预览损坏时局部降级，
/// 嵌套、负根、跨评论主体或跨根的行被丢弃。
@Suite("Comment API rows", .timeLimit(.minutes(1)))
struct CommentAPIClientRowTests {
    @Test
    func topRepliesRemainInServerOrderWithoutInventingProvenance() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var highlighted = try #require(replies.first)
            highlighted["rpid"] = 104
            highlighted["root"] = 0
            highlighted["parent"] = 0
            highlighted["replies"] = []
            data["top_replies"] = [highlighted]
            replies.removeFirst()
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(page.threads.map(\.id.rawValue) == [101, 104, 103])
        let highlighted = try #require(available(page.threads[1].root))
        #expect(highlighted.provenance.isEmpty)
    }

    @Test
    func malformedEnhancementsDoNotDiscardReadableComment() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var reply = replies[0]
            var member = try #require(reply["member"] as? [String: Any])
            member["avatar"] = 42
            member["sex"] = ["unexpected"]
            member["level_info"] = "unexpected"
            member["vip"] = "unexpected"
            member["official_verify"] = "unexpected"
            member["is_senior_member"] = "unexpected"
            reply["member"] = member
            reply["reply_control"] = "unexpected"
            var content = try #require(reply["content"] as? [String: Any])
            content["emote"] = ["fixture": 42]
            content["jump_url"] = ["fixture": 42]
            content["members"] = [42]
            content["pictures"] = [
                ["img_src": "https://example.invalid/fixture.png"],
                42
            ]
            reply["content"] = content
            replies[0] = reply
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        let details = try #require(
            page.threads.first(where: { $0.id.rawValue == 102 })
                .flatMap { available($0.root) }
        )
        #expect(details.content.message == "主评论与 @回复用户")
        #expect(details.content.pictureCount == 2)
        #expect(details.content.links.isEmpty)
        #expect(details.author.level == nil)
        #expect(!details.author.isHardcoreMember)

        let replyResponse = try mutatedFixture("comment-replies") { data in
            data["upper"] = "unexpected"
        }
        let replyRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [replyResponse])
            )
        )
        let replyPage = try await replyRepository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )
        #expect(replyPage.replies.map(\.id.rawValue) == [211])
        let reply = try #require(available(replyPage.replies[0]))
        #expect(!reply.author.isUploader)
    }

    @Test
    func malformedPageEnhancementsAndReplyPreviewDegradeLocally() async throws {
        let response = try mutatedFixture("comment-main") { data in
            data["top_replies"] = 42
            data["top"] = "unexpected"
            data["upper"] = ["unexpected"]
            var replies = try #require(data["replies"] as? [[String: Any]])
            replies[0]["replies"] = "unexpected"
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        let thread = try #require(page.threads.first(where: { $0.id.rawValue == 102 }))
        let details = try #require(available(thread.root))
        #expect(details.content.message == "主评论与 @回复用户")
        #expect(!details.author.isUploader)
        #expect(thread.replyPreview.isEmpty)
    }

    @Test
    func rootPageRejectsNestedAndNegativeRootRowsAndMapsHardcoreMembership() async throws {
        let response = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var nested = replies[0]
            nested["root"] = 101
            nested["parent"] = 101
            var negativeRoot = replies[0]
            negativeRoot["rpid"] = 106
            negativeRoot["root"] = -1
            negativeRoot["parent"] = -1
            var unavailable = replies[1]
            unavailable["rpid"] = 105
            unavailable["state"] = 0
            unavailable["oid"] = 700_001
            unavailable["type"] = 1
            unavailable["root"] = 0
            unavailable["parent"] = 0
            unavailable["ctime"] = 1_700_000_400
            unavailable["like"] = 0
            unavailable["rcount"] = 0
            unavailable["member"] = [
                "mid": "305",
                "uname": "硬核会员",
                "is_senior_member": 1
            ]
            unavailable["content"] = ["message": "硬核会员评论"]
            replies = [nested, negativeRoot, unavailable]
            data["replies"] = replies
        }
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [response],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let page = try await repository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )

        #expect(!page.threads.contains(where: { [102, 106].contains($0.id.rawValue) }))
        let details = try #require(
            page.threads.first(where: { $0.id.rawValue == 105 })
                .flatMap { available($0.root) }
        )
        #expect(details.author.isHardcoreMember)
    }

    @Test
    func unavailableRowsCannotCrossCommentSubjects() async throws {
        let rootResponse = try mutatedFixture("comment-main") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            var unavailable = replies[1]
            unavailable["oid"] = 999_999
            unavailable["type"] = 1
            replies[1] = unavailable
            data["replies"] = replies
        }
        let rootRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(
                    responses: [rootResponse],
                    answersWBINavOnce: true
                ),
                timestampProvider: { 1_700_000_000 }
            )
        )

        let rootPage = try await rootRepository.rootComments(
            for: .video(aid: 700_001),
            sort: .hot,
            after: nil
        )
        #expect(!rootPage.threads.contains(where: { $0.id.rawValue == 103 }))

        let replyResponse = try mutatedFixture("comment-replies") { data in
            var replies = try #require(data["replies"] as? [[String: Any]])
            replies[0]["state"] = 7
            replies[0]["oid"] = 999_999
            replies[0]["type"] = 1
            data["replies"] = replies
        }
        let replyRepository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [replyResponse])
            )
        )
        let replyPage = try await replyRepository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )
        #expect(replyPage.replies.isEmpty)
    }

    @Test
    func replyPageDropsRowsFromAnotherRoot() async throws {
        let fixtureResponse = try fixtureResponse("comment-replies")
        let body = try #require(String(data: fixtureResponse.body, encoding: .utf8))
        let response = HTTPResponse(
            statusCode: 200,
            headers: fixtureResponse.headers,
            body: Data(
                body.replacingOccurrences(
                    of: #""root": 102"#,
                    with: #""root": 999"#
                ).utf8
            )
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [response])
            )
        )

        let page = try await repository.replies(
            for: .video(aid: 700_001),
            rootID: CommentID(rawValue: 102),
            page: 2,
            pageSize: 10
        )

        #expect(page.replies.isEmpty)
    }
}
