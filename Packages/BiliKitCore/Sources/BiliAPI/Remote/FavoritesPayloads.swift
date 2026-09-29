import BiliApplication
import BiliModels
import Foundation

struct FavFolderListPayload: Decodable, Sendable {
    let count: Int?
    let list: [FavFolderPayload]?

    func model() -> [FavFolder] {
        (list ?? []).compactMap { $0.model() }
    }
}

struct FavFolderPayload: Decodable, Sendable {
    let id: Int64
    let fid: Int64?
    let mid: Int64?
    let title: String
    let mediaCount: Int?
    let favState: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case fid
        case mid
        case title
        case mediaCount = "media_count"
        case favState = "fav_state"
    }

    func model() -> FavFolder? {
        guard !title.isEmpty else { return nil }
        return FavFolder(
            mediaID: id,
            fid: fid ?? 0,
            mid: mid ?? 0,
            title: title,
            mediaCount: max(0, mediaCount ?? 0),
            isFavored: favState.map { $0 == 1 }
        )
    }
}

struct FavResourceListPayload: Decodable, Sendable {
    let info: FavFolderPayload?
    let medias: [FavMediaItemPayload]?
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case info
        case medias
        case hasMore = "has_more"
    }

    func model(pageNumber: Int) -> FavFolderPage {
        let items = (medias ?? []).compactMap { $0.model() }
        return FavFolderPage(
            info: info?.model(),
            items: items,
            pageNumber: pageNumber,
            hasMore: hasMore ?? false
        )
    }
}

struct FavMediaItemPayload: Decodable, Sendable {
    let id: Int64?
    let bvid: String?
    let title: String
    let cover: String?
    let duration: Int?
    let upper: FavUpperPayload?
    let cntInfo: FavCntInfoPayload?
    let favTime: Int64?

    private enum CodingKeys: String, CodingKey {
        case id
        case bvid
        case title
        case cover
        case duration
        case upper
        case cntInfo = "cnt_info"
        case favTime = "fav_time"
    }

    func model() -> FavFolderItem? {
        guard let bvid,
              bvid.hasPrefix("BV"),
              bvid.count <= 24,
              !title.isEmpty
        else {
            return nil
        }

        let owner = VideoOwner(
            id: upper?.mid ?? 0,
            name: upper?.name ?? "未知 UP 主",
            avatarURL: upper?.face.flatMap(WebImageURL.parse)
        )

        return FavFolderItem(
            aid: id ?? 0,
            bvid: bvid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            owner: owner,
            durationSeconds: max(0, duration ?? 0),
            playCount: cntInfo?.play ?? 0,
            danmakuCount: cntInfo?.danmaku ?? 0,
            favoredAt: Date(timeIntervalSince1970: TimeInterval(favTime ?? 0))
        )
    }
}

struct FavUpperPayload: Decodable, Sendable {
    let mid: Int64?
    let name: String?
    let face: String?
}

struct FavCntInfoPayload: Decodable, Sendable {
    let play: Int64?
    let danmaku: Int64?
}
