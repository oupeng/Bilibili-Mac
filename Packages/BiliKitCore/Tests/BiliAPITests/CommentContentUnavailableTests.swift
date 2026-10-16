import BiliApplication
import BiliModels
import BiliNetworking
import Testing

@testable import BiliAPI

/// 稿件或根评论不存在、不可见时，评论读取与内容域同样归为不可重试的 `contentUnavailable`。
@Suite(.timeLimit(.minutes(1)))
struct CommentContentUnavailableTests {
    @Test(arguments: [-404, 62002, 62004])
    func missingOrHiddenSubjectIsContentUnavailable(code: Int) async {
        let transport = StubTransport(
            responses: [jsonResponse(#"{"code":\#(code),"message":"fixture"}"#)],
            answersWBINavOnce: true
        )
        let repository = BiliCommentRepository(
            client: BiliAPIClient(transport: transport, timestampProvider: { 1_700_000_000 })
        )

        await #expect(throws: CommentReadError.contentUnavailable) {
            try await repository.rootComments(for: .video(aid: 700_001), sort: .hot, after: nil)
        }
    }
}
