import BiliApplication
import BiliModels
import Foundation

struct FavoriteFolderListPayload: Decodable, Sendable {
    let count: Int?
    let list: [FavoriteFolderPayload]?

    func model() -> [FavoriteFolder] {
        guard let list else { return [] }
        return list.compactMap { $0.model() }
    }
}

struct FavoriteFolderPayload: Decodable, Sendable {
    let id: Int64
    let title: String
    let mediaCount: Int?
    let cover: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case mediaCount = "media_count"
        case cover
    }

    func model() -> FavoriteFolder? {
        guard id > 0, !title.isEmpty else { return nil }
        return FavoriteFolder(
            id: id,
            title: title,
            mediaCount: mediaCount ?? 0,
            coverURL: cover.flatMap(WebImageURL.parse)
        )
    }
}

struct FavoriteItemListPayload: Decodable, Sendable {
    let info: FavoriteFolderPayload?
    let medias: [FavoriteItemPayload]?
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case info
        case medias
        case hasMore = "has_more"
    }

    func model(page: Int) throws -> FavoriteItemsPage {
        let items = try (medias ?? []).compactMap { try $0.model() }.uniquedByBVID(\.bvid)
        return FavoriteItemsPage(
            items: items,
            pageNumber: page,
            hasMore: hasMore ?? false
        )
    }
}

struct FavoriteItemPayload: Decodable, Sendable {
    let id: Int64
    let type: Int?
    let title: String
    let cover: String
    let duration: Int?
    let favAt: Int64?
    let bvid: String?
    let upper: FavoriteUpperPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case cover
        case duration
        case favAt = "fav_time"
        case bvid
        case upper
    }

    func model() throws -> FavoriteItem? {
        let resolvedBVID = bvid ?? ""
        guard resolvedBVID.hasPrefix("BV") || id > 0, !title.isEmpty else {
            return nil
        }
        let itemBVID = resolvedBVID.isEmpty ? "aid-\(id)" : resolvedBVID
        let ownerModel = upper?.model() ?? VideoOwner(id: 0, name: "")
        let favoriteDate = Date(timeIntervalSince1970: TimeInterval(favAt ?? 0))
        return FavoriteItem(
            bvid: itemBVID,
            aid: id,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: WebImageURL.parse(cover),
            owner: ownerModel,
            durationSeconds: duration ?? 0,
            favoriteAt: favoriteDate
        )
    }
}

struct FavoriteUpperPayload: Decodable, Sendable {
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
