import BiliApplication
import Foundation

/// 稍后再看读取。列表只属于当前账户，所以只按账户读取，本地无凭据时直接失败（见 SECURITY-MODEL §3）；
/// 只读，不涉及任何写请求。
extension BiliAPIClient {
    /// 稍后再看每页条数；请求的 `ps` 与“是否还有下一页”的推算共用这个值。
    ///
    /// 与网页端相同取 20。接口允许的上限未经确认：调大前先核对接口仍按请求的条数返回，否则按总条数推出的
    /// 下一页会与实际错位。
    static let watchLaterPageSize = 20

    /// 读取第 `page` 页（从 1 开始），最新加入的在前。
    public func watchLater(page: Int) async throws -> WatchLaterPage {
        guard page > 0 else {
            throw BiliAPIError.invalidRequest
        }
        // `viewed=0` 不按是否看过筛选，`key` 为空表示不按关键词搜索，`asc=0` 让最新加入的排在前面；
        // `web_location` 是网页端稍后再看页的来源标记。
        let parameters = [
            "pn": String(page),
            "ps": String(Self.watchLaterPageSize),
            "viewed": "0",
            "key": "",
            "asc": "0",
            "web_location": "333.881"
        ]
        let payload: WatchLaterPayload = try await signedRequest(
            path: BiliAccountReadPath.watchLater,
            parameters: { parameters },
            send: { url in
                try await get(
                    url: url,
                    referer: "https://www.bilibili.com/watchlater/",
                    access: .accountRead(missingCredential: .fail)
                )
            }
        )
        return try payload.model(pageNumber: page, pageSize: Self.watchLaterPageSize)
    }
}
