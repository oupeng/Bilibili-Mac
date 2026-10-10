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
        let sessionEpoch = authenticatedSessionEpoch
        let parameters = [
            "mid": String(ownerID),
            "pn": String(page),
            "ps": String(Self.uploaderVideoPageSize),
            "order": order.apiValue
        ]
        // 403 在这里通常是风控而不是 key 过期；只在 -403／v_voucher 时刷新 key 重试。
        return try await withWBIKeyRefresh(retryingHTTPForbidden: false) { forceKeyRefresh in
            let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            let query = try wbiSigner.sign(
                parameters: parameters,
                keys: keys,
                timestamp: timestampProvider()
            )
            let payload: UploaderVideoSearchPayload = try await get(
                url: try endpoint(
                    path: "/x/space/wbi/arc/search",
                    percentEncodedQuery: query
                ),
                referer: "https://space.bilibili.com/\(ownerID)/",
                access: .accountRead(
                    missingCredential: .fail,
                    mapsAuthenticationInvalidation: true
                )
            )
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return payload.model(pageNumber: page, pageSize: Self.uploaderVideoPageSize)
        }
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
