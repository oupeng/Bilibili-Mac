import BiliApplication
import BiliModels
import Foundation

/// 首页推荐的「不感兴趣」与撤销：经共用的写管线 `postForm`、账户写授权器绑定窗口账户。
///
/// 字段照网页的推荐流反馈发送（`app_id`、`platform`、`spmid` 等是接口必需的固定值，不是可省的统计字段），撤销与反馈
/// 字段完全相同。网页对这两个接口签 WBI，这里不签，见授权器 schema 表的说明。
extension BiliAPIClient {
    /// 「不感兴趣」的 Referer：首页推荐在站点首页。
    private static let recommendationFeedbackReferer = "https://www.bilibili.com/"

    /// 对首页推荐的一条说「不感兴趣」（`cancel` 为 false），或撤销那次反馈。
    public func sendRecommendationFeedback(
        _ feedback: RecommendationFeedback,
        cancel: Bool,
        accountID: Int64
    ) async throws {
        guard hasAccountWriteAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        guard accountID > 0, let aid = BiliVideoAID.aid(fromBVID: feedback.target.bvid) else {
            throw BiliAPIError.invalidRequest
        }
        try await postForm(
            url: try endpoint(
                path: cancel
                    ? BiliAccountWritePath.recommendationDislikeCancel
                    : BiliAccountWritePath.recommendationDislike
            ),
            fields: [
                ("app_id", "100"),
                ("platform", "5"),
                ("from_spmid", ""),
                ("spmid", "333.1007.0.0"),
                ("goto", "av"),
                ("id", String(aid)),
                ("mid", String(feedback.uploaderID)),
                ("track_id", feedback.trackID),
                ("feedback_page", "1"),
                ("reason_id", String(feedback.reason.rawValue))
            ],
            referer: Self.recommendationFeedbackReferer,
            origin: Self.accountWriteOrigin,
            access: .accountWrite(expectedAccountID: accountID)
        )
    }
}
