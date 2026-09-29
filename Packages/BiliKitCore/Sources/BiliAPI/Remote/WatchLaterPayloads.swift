import BiliApplication
import BiliModels
import Foundation

struct WatchLaterPayload: Decodable, Sendable {
    let count: Int?
    let list: [WatchLaterItemPayload]?

    func model() throws -> [WatchLaterItem] {
        guard let list else { return [] }
        return try list.compactMap { try $0.model() }.uniquedByBVID(\.bvid)
    }
}

struct WatchLaterItemPayload: Decodable, Sendable {
    let aid: Int64
    let bvid: String?
    let title: String
    let pic: String
    let duration: Int?
    let addAt: Int64?
    let progress: Int?
    let owner: WatchLaterOwnerPayload?

    private enum CodingKeys: String, CodingKey {
        case aid
        case bvid
        case title
        case pic
        case duration
        case addAt = "add_at"
        case progress
        case owner
    }

    func model() throws -> WatchLaterItem? {
        let bvidString = bvid ?? ""
        guard bvidString.hasPrefix("BV") || aid > 0, !title.isEmpty else {
            return nil
        }
        let resolvedBVID = bvidString.isEmpty ? "aid-\(aid)" : bvidString
        let ownerModel = owner?.model() ?? VideoOwner(id: 0, name: "")
        let addedDate = Date(timeIntervalSince1970: TimeInterval(addAt ?? 0))
        return WatchLaterItem(
            bvid: resolvedBVID,
            aid: aid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: WebImageURL.parse(pic),
            owner: ownerModel,
            durationSeconds: duration ?? 0,
            addedAt: addedDate,
            progressSeconds: progress ?? 0
        )
    }
}

struct WatchLaterOwnerPayload: Decodable, Sendable {
    let mid: Int64
    let name: String
    let face: String?

    func model() -> VideoOwner {
        VideoOwner(
            id: mid,
            name: name,
            avatarURL: face.flatMap(WebImageURL.parse)
        )
    }
}
