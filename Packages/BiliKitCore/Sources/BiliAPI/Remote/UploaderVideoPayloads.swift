import BiliModels
import Foundation

struct UploaderVideoSearchPayload: Decodable, Sendable {
    let list: UploaderVideoListPayload
    let page: UploaderVideoPagePayload

    func model(pageNumber: Int, pageSize: Int) -> UploaderVideoPage {
        let items = list.vlist ?? []
        return UploaderVideoPage(
            videos: items.compactMap { $0.model() },
            pageNumber: pageNumber,
            pageSize: pageSize,
            totalCount: max(0, page.count),
            hasMore: !items.isEmpty && pageNumber * pageSize < page.count
        )
    }
}

struct UploaderVideoListPayload: Decodable, Sendable {
    let vlist: [UploaderVideoItemPayload]?
}

struct UploaderVideoPagePayload: Decodable, Sendable {
    let count: Int
}

struct UploaderVideoItemPayload: Decodable, Sendable {
    let bvid: String
    let title: String
    let pic: String
    /// 时长是 `"MM:SS"` 或 `"H:MM:SS"` 字符串，不是秒数。
    let length: String
    let play: FlexibleInt64
    let videoReview: FlexibleInt64?
    let created: Int64
    let isUnionVideo: Int?

    enum CodingKeys: String, CodingKey {
        case bvid, title, pic, length, play, created
        case videoReview = "video_review"
        case isUnionVideo = "is_union_video"
    }

    func model() -> UploaderVideo? {
        guard BiliAPIClient.isValidBVID(bvid) else { return nil }
        return UploaderVideo(
            bvid: bvid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: WebImageURL.parse(pic),
            durationSeconds: Self.seconds(fromClock: length),
            // 数据被隐藏时接口给 "--"，FlexibleInt64 解为 -1。
            viewCount: play.value >= 0 ? play.value : nil,
            danmakuCount: videoReview.flatMap { $0.value >= 0 ? $0.value : nil },
            publishedAt: Date(timeIntervalSince1970: TimeInterval(created)),
            isCollaboration: (isUnionVideo ?? 0) != 0
        )
    }

    static func seconds(fromClock value: String) -> Int? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else { return nil }
        var seconds = 0
        for component in components {
            guard let number = Int(component), number >= 0 else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }
}
