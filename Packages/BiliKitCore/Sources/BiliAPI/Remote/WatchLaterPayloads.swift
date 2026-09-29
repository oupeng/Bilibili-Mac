import BiliApplication
import BiliModels
import Foundation

struct WatchLaterListPayload: Decodable, Sendable {
    let count: Int?
    let list: [WatchLaterItemPayload]?

    func model() throws -> WatchLaterPage {
        let items = try (list ?? []).compactMap { try $0.model() }
        return WatchLaterPage(items: items, count: count ?? items.count)
    }
}

struct WatchLaterItemPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String?
    let title: String
    let pic: String
    let owner: WatchLaterOwnerPayload?
    let duration: Int?
    let progress: Int?
    let addAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case aid
        case bvid
        case title
        case pic
        case owner
        case duration
        case progress
        case addAt = "add_at"
    }

    func model() throws -> WatchLaterItem? {
        guard let bvid,
              bvid.hasPrefix("BV"),
              bvid.count <= 24,
              !title.isEmpty
        else {
            return nil
        }

        let ownerModel: VideoOwner
        if let owner {
            ownerModel = VideoOwner(
                id: owner.mid ?? 0,
                name: owner.name ?? "未知 UP 主",
                avatarURL: owner.face.flatMap(WebImageURL.parse)
            )
        } else {
            ownerModel = VideoOwner(id: 0, name: "未知 UP 主")
        }

        let dur = max(0, duration ?? 0)
        let prog = max(0, progress ?? 0)
        let addedDate = Date(timeIntervalSince1970: TimeInterval(addAt ?? 0))

        return WatchLaterItem(
            bvid: bvid,
            aid: aid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: WebImageURL.parse(pic),
            owner: ownerModel,
            progressSeconds: min(prog, dur > 0 ? dur : prog),
            durationSeconds: dur,
            addedAt: addedDate
        )
    }
}

struct WatchLaterOwnerPayload: Decodable, Sendable {
    let mid: Int64?
    let name: String?
    let face: String?
}
