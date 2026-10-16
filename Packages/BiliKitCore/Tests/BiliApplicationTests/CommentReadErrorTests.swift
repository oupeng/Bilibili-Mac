import BiliApplication
import Testing

/// 评论域的“是否复核、是否重试”只由 `CommentReadError` 决定，规则与内容域一致。
struct CommentReadErrorTests {
    @Test(
        arguments: [
            (CommentReadError.authenticationInvalid, true),
            (.authenticationRequired, false),
            (.authenticationUnavailable, false),
            (.requestRestricted, false),
            (.contentUnavailable, false),
            (.invalidRequest, false)
        ]
    )
    func onlyInvalidCredentialsRequestAccountRevalidation(
        error: CommentReadError,
        revalidates: Bool
    ) {
        #expect(error.requiresAccountRevalidation == revalidates)
    }

    @Test(
        arguments: [
            (CommentReadError.invalidRequest, false),
            (.authenticationRequired, false),
            (.contentUnavailable, false),
            (.closed, false),
            (.authenticationInvalid, true),
            (.authenticationUnavailable, true),
            (.requestRestricted, true),
            (.serviceRejected(code: -500), true),
            (.transportFailure, true),
            (.invalidResponse, true),
            (.unavailable, true)
        ]
    )
    func outcomesThatRetryCannotChangeAreNotRetryable(
        error: CommentReadError,
        retryable: Bool
    ) {
        #expect(error.isRetryable == retryable)
    }
}
