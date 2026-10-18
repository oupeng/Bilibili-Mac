import BiliModels
import BiliNetworking
import Foundation

/// `/x/web-interface/search/square` 的 `data`；只读取 `trending.list`，忽略运营置顶等其他字段。
///
/// 这里只做 DTO 到模型的映射；能否搜索、去重、展示名回退与条数上限由 `TrendingSearchUseCase` 决定。
struct TrendingSearchPayload: Decodable, Sendable {
    let trending: TrendingSearchListPayload

    func model() -> [TrendingSearchKeyword] {
        trending.list.compactMap(\.value).map { $0.model() }
    }
}

/// 热搜的 `trending`：单项解码失败只丢该项。
struct TrendingSearchListPayload: Decodable, Sendable {
    let list: [LossyDecodable<TrendingSearchKeywordPayload>]
}

/// 热搜的一项：搜索词、展示名与图标。
struct TrendingSearchKeywordPayload: Decodable, Sendable {
    let keyword: String
    let showName: String?
    /// 图标地址：`http:` 与协议相对地址先升级为 HTTPS，再须通过 `BiliBFSImageURLPolicy`（见
    /// SECURITY-MODEL §4）。
    let icon: String?

    private enum CodingKeys: String, CodingKey {
        case keyword
        case showName = "show_name"
        case icon
    }

    /// 不合规的图标只丢图标、保留文字。
    func model() -> TrendingSearchKeyword {
        TrendingSearchKeyword(
            keyword: keyword,
            displayName: showName ?? "",
            iconURL:
                icon
                .flatMap(WebImageURL.parse)
                .flatMap { BiliBFSImageURLPolicy.allows($0) ? $0 : nil }
        )
    }
}
