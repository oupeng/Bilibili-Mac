import Foundation

struct RecentRankPayload: Decodable, Sendable {
    let result: [RecentRankSubmissionPayload]?
}

struct RecentRankSubmissionPayload: Decodable, Sendable {
    let bvid: String
    let duration: Int
    let senddate: Int64
    let mid: Int64
    let play: FlexibleInt64
}

struct RecentSubmissionDetailPayload: Decodable, Sendable {
    let bvid: String
    let cid: Int64
    let duration: Int
    let pubdate: Int64
    let tid: Int
    let owner: RecentOwnerPayload
}

struct RecentOwnerPayload: Decodable, Sendable {
    let mid: Int64
}
