import BiliModels

/// 「不感兴趣」的原因：网页首页推荐只给这两个，取值是接口的 `reason_id`。
public enum RecommendationDislikeReason: Int, Sendable, Hashable, CaseIterable {
    case content = 1
    case uploader = 4
}

/// 对首页推荐的一条视频说「不感兴趣」：哪个视频、它的 UP 主与推荐流追踪 ID，以及原因。
///
/// 撤销必须带同样的字段（接口按它们找到那次反馈），所以 Browse 记下发出的这一份，撤销时原样交回。
public struct RecommendationFeedback: Sendable, Hashable {
    public let target: VideoWriteTarget
    public let uploaderID: Int64
    public let trackID: String
    public let reason: RecommendationDislikeReason

    /// 追踪 ID 为空或 UP 主 ID 不是正数时为 nil：推荐流没给追踪 ID 的条目不提供反馈，接口也不收没有 UP 主的反馈。
    public init?(
        target: VideoWriteTarget,
        uploaderID: Int64,
        trackID: String,
        reason: RecommendationDislikeReason
    ) {
        guard !trackID.isEmpty, uploaderID > 0 else { return nil }
        self.target = target
        self.uploaderID = uploaderID
        self.trackID = trackID
        self.reason = reason
    }
}

/// 「不感兴趣」与撤销的写入 port。
///
/// 实现是 BiliAPI 的 `BiliRecommendationFeedbackRepository`，只经 `RecommendationFeedbackUseCase` 调用；`accountID` 交给
/// 写授权器做账户绑定。失败统一抛出 `AccountWriteError`，取消原样传播；不重试、不排队。
public protocol RecommendationFeedbackRepository: Sendable {
    func dislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws
    func cancelDislike(_ feedback: RecommendationFeedback, accountID: Int64) async throws
}

/// 「不感兴趣」与撤销；校验账户后执行，成功时给出要分发的效果。
public struct RecommendationFeedbackUseCase: Sendable {
    private let repository: any RecommendationFeedbackRepository

    public init(repository: any RecommendationFeedbackRepository) {
        self.repository = repository
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func dislike(
        _ feedback: RecommendationFeedback,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.dislike(feedback, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .recommendationDisliked(feedback))
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func cancelDislike(
        _ feedback: RecommendationFeedback,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.cancelDislike(feedback, accountID: accountID)
        return AccountWriteEffect(
            accountID: accountID,
            change: .recommendationDislikeCancelled(feedback)
        )
    }
}
