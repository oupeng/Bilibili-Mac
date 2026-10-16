import BiliApplication
import BiliModels
import BiliNetworking
import Testing

@testable import BiliAPI

/// 客户端无法发出的评论请求（授权器 allowlist 拒绝、参数不合规）是 `invalidRequest`，不是接口数据错误，
/// 也不发出业务请求；见 SECURITY-MODEL §3。
@Suite(.timeLimit(.minutes(1)))
struct CommentRequestRejectionTests {
    @Test
    func authorizerDenialOfRootCommentsIsAnInvalidRequest() async {
        let transport = StubTransport(responses: [], answersWBINavOnce: true)
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(.denied)),
                timestampProvider: { 1_700_000_000 }
            )
        )

        await #expect(throws: CommentReadError.invalidRequest) {
            try await repository.rootComments(for: .video(aid: 700_001), sort: .hot, after: nil)
        }
        #expect(transport.businessRequests().isEmpty)
    }

    @Test
    func authorizerDenialOfRepliesIsAnInvalidRequest() async {
        let transport = StubTransport(responses: [])
        let repository = BiliCommentRepository(
            client: BiliAPIClient(
                transport: transport,
                requestAuthorizer: StubAuthorizer(.fail(.denied))
            )
        )

        await #expect(throws: CommentReadError.invalidRequest) {
            try await repository.replies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                page: 1,
                pageSize: 10
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }

    @Test
    func malformedReplyPageRequestIsAnInvalidRequest() async {
        let transport = StubTransport(responses: [])
        let repository = BiliCommentRepository(client: BiliAPIClient(transport: transport))

        await #expect(throws: CommentReadError.invalidRequest) {
            try await repository.replies(
                for: .video(aid: 700_001),
                rootID: CommentID(rawValue: 102),
                page: 1,
                pageSize: 20
            )
        }
        #expect(transport.capturedRequests().isEmpty)
    }
}
