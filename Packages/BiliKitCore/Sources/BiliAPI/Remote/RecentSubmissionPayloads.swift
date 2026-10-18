import Foundation

/// `/x/web-interface/newlist_rank` 的 `data`：分区近期投稿，只供线路测速发现样本。
///
/// 由 `BiliAPIClient.recentSubmissions` 匿名读取，`CDNBenchmarkSampleDiscoverer` 按 BVID 形状、
/// MID、播放量、投稿时间与时长筛选；不进入任何界面模型。
struct RecentRankPayload: Decodable, Sendable {
    let result: [RecentRankSubmissionPayload]?
}

/// 近期投稿列表的一项：BVID、时长、投稿时间、UP 主 MID 与播放量。
struct RecentRankSubmissionPayload: Decodable, Sendable {
    let bvid: String
    let duration: Int
    let senddate: Int64
    let mid: Int64
    let play: FlexibleInt64
}

/// 测速样本的视频详情投影，与主详情同一个 `/x/web-interface/wbi/view` 签名请求，只按账户读取。
///
/// 发现器要求 BVID、UP 主与分区都与列表项一致且 `cid` 为正，才把它当作样本。
struct RecentSubmissionDetailPayload: Decodable, Sendable {
    let bvid: String
    let cid: Int64
    let duration: Int
    let pubdate: Int64
    let tid: Int
    let owner: RecentOwnerPayload
}

/// 测速样本详情里的 UP 主，只取 MID。
struct RecentOwnerPayload: Decodable, Sendable {
    let mid: Int64
}
