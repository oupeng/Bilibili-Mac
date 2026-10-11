import BiliModels
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

struct TrendingSearchListPayload: Decodable, Sendable {
    let list: [LossyDecodable<TrendingSearchKeywordPayload>]
}

struct TrendingSearchKeywordPayload: Decodable, Sendable {
    let keyword: String
    let showName: String?
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
