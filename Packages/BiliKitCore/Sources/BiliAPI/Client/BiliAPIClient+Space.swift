import BiliModels
import Foundation

/// UP 主空间读取。游客请求会被间歇风控，所以只按账户读取，本地无凭据时直接失败。
extension BiliAPIClient {
    static let uploaderVideoPageSize = 30
    /// 页码上限：远超任何 UP 主的实际投稿页数，用来拒绝异常输入。
    static let uploaderVideoMaximumPage = 10_000

    public func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage {
        guard ownerID > 0, (1...Self.uploaderVideoMaximumPage).contains(page) else {
            throw BiliAPIError.invalidRequest
        }
        let parameters = [
            "mid": String(ownerID),
            "pn": String(page),
            "ps": String(Self.uploaderVideoPageSize),
            "order": order.apiValue
        ]
        let payload: UploaderVideoSearchPayload = try await signedRequest(
            path: BiliAccountReadPath.uploaderVideos,
            parameters: { parameters },
            send: { url in
                try await get(
                    url: url,
                    referer: "https://space.bilibili.com/\(ownerID)/",
                    access: .accountRead(missingCredential: .fail)
                )
            }
        )
        return payload.model(pageNumber: page, pageSize: Self.uploaderVideoPageSize)
    }
}

extension UploaderVideoOrder {
    fileprivate var apiValue: String {
        switch self {
        case .newest: "pubdate"
        case .mostPlayed: "click"
        case .mostFavorited: "stow"
        }
    }
}
