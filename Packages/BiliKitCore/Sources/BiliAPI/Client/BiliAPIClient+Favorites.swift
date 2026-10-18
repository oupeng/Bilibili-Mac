import BiliApplication
import BiliModels
import Foundation

/// 收藏夹读取：自己创建的收藏夹列表与夹内的一页。两者只属于当前账户，所以只按账户读取，本地无凭据时直接失败；
/// 只读，不涉及任何写请求（见 SECURITY-MODEL §3）。
///
/// 都不签 WBI：网页端对这两个接口不签名；签名不是认证，多签反而偏离网页端的请求形状。
extension BiliAPIClient {
    /// 收藏夹内每页条数；请求的 `ps` 与总页数的推算共用这个值。
    ///
    /// 接口接受 1–40，取与网页端相同的上限 40：页数最少，越界与空页也最少。
    static let favoriteFolderPageSize = 40
    /// 收藏夹业务码：请求的收藏夹不存在（已删除或不属于当前账户）。
    static let favoriteFolderMissingCode = 11_010

    /// 读取 `ownerID` 自己创建的全部收藏夹，一次取全、不分页，按接口顺序返回。
    ///
    /// `ownerID` 由调用方从窗口账户范围给出，这里不读取账户。`data` 为 null 时返回空数组：Cookie 失效时接口不报
    /// -101 而是退化为访客视角，是否可疑由 `FavoritesUseCase` 判断。
    public func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        guard ownerID > 0 else { throw BiliAPIError.invalidRequest }
        let payload: FavoriteFolderListPayload
        do {
            payload = try await get(
                url: try endpoint(
                    path: BiliAccountReadPath.favoriteFolders,
                    queryItems: [URLQueryItem(name: "up_mid", value: String(ownerID))]
                ),
                referer: "https://space.bilibili.com/\(ownerID)/favlist",
                access: .accountRead(missingCredential: .fail)
            )
        } catch BiliAPIError.missingData {
            return []
        }
        return payload.model()
    }

    /// 按请求读取收藏夹内的一页（`pn` 从 1 开始）。
    ///
    /// `type=0` 只搜当前收藏夹，`tid=0` 不按分区筛选；`platform=web` 必须带，否则合集条目会被接口丢掉。关键词按
    /// RFC 3986 unreserved 编码（`queryItems` 会保留 `+`，被服务端当成空格）。`data` 或 `info` 为 null 与业务码
    /// 11010 都说明收藏夹不存在，前两者按 `missingData` 报告、11010 原样作为业务拒绝，由
    /// `BiliFavoritesRepository` 一起映射为内容不存在。
    public func favoriteFolderPage(
        request: FavoriteFolderRequest
    ) async throws -> FavoriteFolderPage {
        guard request.isValid else { throw BiliAPIError.invalidRequest }
        let parameters = [
            ("media_id", String(request.folderID)),
            ("pn", String(request.page)),
            ("ps", String(Self.favoriteFolderPageSize)),
            ("keyword", request.keyword),
            ("order", request.order.apiValue),
            ("type", "0"),
            ("tid", "0"),
            ("platform", "web")
        ]
        var encodedPairs: [String] = []
        for (name, value) in parameters {
            guard let encoded = URLQueryUnreservedEncoding.encode(value) else {
                throw BiliAPIError.invalidRequest
            }
            encodedPairs.append("\(name)=\(encoded)")
        }
        let payload: FavoriteFolderPagePayload = try await get(
            url: try endpoint(
                path: BiliAccountReadPath.favoriteFolderContent,
                percentEncodedQuery: encodedPairs.joined(separator: "&")
            ),
            referer: "https://space.bilibili.com/",
            access: .accountRead(missingCredential: .fail)
        )
        return try payload.model(pageNumber: request.page, pageSize: Self.favoriteFolderPageSize)
    }
}

extension FavoriteFolderOrder {
    /// 排序在接口 `order` 参数里的取值。
    fileprivate var apiValue: String {
        switch self {
        case .recentlyFavorited: "mtime"
        case .mostPlayed: "view"
        case .recentlyPublished: "pubtime"
        }
    }
}
