import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 主评论（WBI 签名）与楼中楼分页。
extension BiliAPIClient {
    /// 评论页正文上限，见 SECURITY-MODEL §4；超出按响应异常失败关闭。
    private static let maximumCommentPageSize = 2 * 1_024 * 1_024

    /// 根评论：WBI 签名，有凭据时按账户读取，本地无凭据时匿名请求同一 endpoint。
    ///
    /// `offset` 是上一页服务端给出的分页游标，由 `BiliCommentRepository` 保管，首页为 nil。
    func commentRootPage(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        offset: String?
    ) async throws -> CommentRemoteRootPage {
        guard subject.type == 1, subject.oid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let paginationData = try JSONSerialization.data(
            withJSONObject: ["offset": offset ?? ""],
            options: [.sortedKeys]
        )
        guard let pagination = String(data: paginationData, encoding: .utf8) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: CommentMainPayload = try await signedRequest(
            path: BiliAccountReadPath.rootComments,
            parameters: {
                [
                    "type": String(subject.type),
                    "oid": String(subject.oid),
                    "mode": sort == .hot ? "3" : "2",
                    "pagination_str": pagination
                ]
            },
            send: { url in
                try await get(
                    url: url,
                    referer: "https://www.bilibili.com/",
                    access: .accountRead(missingCredential: .useAnonymousRequest),
                    maximumResponseSize: Self.maximumCommentPageSize
                )
            }
        )
        return try payload.page(for: subject)
    }

    /// 楼中楼：不签 WBI，授权方式与根评论相同；只接受每页 10 条。
    func commentReplyPage(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentRemoteReplyPage {
        guard subject.type == 1, subject.oid > 0,
            rootID.rawValue > 0, page > 0, pageSize == 10
        else { throw BiliAPIError.invalidRequest }
        let payload: CommentReplyListPayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.commentReplies,
                queryItems: [
                    URLQueryItem(name: "type", value: String(subject.type)),
                    URLQueryItem(name: "oid", value: String(subject.oid)),
                    URLQueryItem(name: "root", value: String(rootID.rawValue)),
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize))
                ]
            ),
            referer: "https://www.bilibili.com/",
            access: .accountRead(missingCredential: .useAnonymousRequest),
            maximumResponseSize: Self.maximumCommentPageSize
        )
        return try payload.page(subject: subject, rootID: rootID)
    }
}
