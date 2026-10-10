import BiliModels
import Foundation

struct UploaderVideoSearchPayload: Decodable, Sendable {
    let list: UploaderVideoListPayload
    let page: UploaderVideoPagePayload

    func model(pageNumber: Int, pageSize: Int) -> UploaderVideoPage {
        UploaderVideoPage(
            videos: (list.vlist ?? []).compactMap { $0.value?.model() },
            pageNumber: pageNumber,
            pageSize: pageSize,
            totalCount: page.count
        )
    }
}

struct UploaderVideoListPayload: Decodable, Sendable {
    /// 单条字段异常只丢弃那一条，不让整页失败。
    let vlist: [LossyDecodable<UploaderVideoItemPayload>]?
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
            durationSeconds: RemoteClockDuration.seconds(length),
            viewCount: play.value,
            danmakuCount: videoReview?.value,
            publishedAt: Date(timeIntervalSince1970: TimeInterval(created)),
            isCollaboration: (isUnionVideo ?? 0) != 0
        )
    }
}
