import BiliAPI
import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

/// 固定首页推荐「不感兴趣」的请求契约：反馈与撤销照网页发同一组字段（稿件 aid、UP 主 mid、推荐流追踪 ID 与原因），
/// 经账户写授权器绑定账户，Referer 是站点首页，不附加 `buvid3`、不签 WBI；业务拒绝保留错误码。
@Suite(.timeLimit(.minutes(1)))
struct BiliAPIClientRecommendationFeedbackTests {
    @Test(arguments: [
        (false, RecommendationDislikeReason.content, "/x/web-interface/feedback/dislike", "1"),
        (true, .uploader, "/x/web-interface/feedback/dislike/cancel", "4")
    ])
    func feedbackSendsTheWebFieldsBoundToTheAccount(
        cancel: Bool,
        reason: RecommendationDislikeReason,
        path: String,
        reasonID: String
    ) async throws {
        let transport = StubTransport(responses: [statusResponse(code: 0)])
        let authorizer = StubSubjectBoundAuthorizer()
        let repository = BiliRecommendationFeedbackRepository(
            client: BiliAPIClient(transport: transport, accountWriteAuthorizer: authorizer)
        )
        let feedback = try feedback(reason: reason)

        if cancel {
            try await repository.cancelDislike(feedback, accountID: 42)
        } else {
            try await repository.dislike(feedback, accountID: 42)
        }

        let authorized = try #require(await authorizer.capturedRequests().last)
        #expect(await authorizer.subjects == ["42"])
        #expect(authorized.url.absoluteString == "https://api.bilibili.com\(path)")
        #expect(authorized.headers["Referer"] == "https://www.bilibili.com/")
        #expect(
            formFields(authorized) == [
                "app_id": "100",
                "platform": "5",
                "from_spmid": "",
                "spmid": "333.1007.0.0",
                "goto": "av",
                "id": "170001",
                "mid": "10001",
                "track_id": "web_rcmd.abc-1",
                "feedback_page": "1",
                "reason_id": reasonID
            ]
        )
        let sent = try #require(transport.capturedRequests().last)
        #expect(sent.headers["Cookie"]?.contains("buvid3=") != true)
        #expect(queryFields(sent).isEmpty)
    }

    @Test
    func businessRejectionKeepsItsCode() async throws {
        let repository = BiliRecommendationFeedbackRepository(
            client: BiliAPIClient(
                transport: StubTransport(responses: [statusResponse(code: 12_345)]),
                accountWriteAuthorizer: StubSubjectBoundAuthorizer()
            )
        )
        let feedback = try feedback(reason: .content)

        await #expect(throws: AccountWriteError.rejected(code: 12_345)) {
            try await repository.dislike(feedback, accountID: 42)
        }
    }

    private func feedback(reason: RecommendationDislikeReason) throws -> RecommendationFeedback {
        let target = try #require(VideoWriteTarget(bvid: "BV17x411w7KC"))
        return try #require(
            RecommendationFeedback(
                target: target,
                uploaderID: 10_001,
                trackID: "web_rcmd.abc-1",
                reason: reason
            )
        )
    }
}
