import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 自己创建的收藏夹列表（`/x/v3/fav/folder/created/list-all`）的 `data`，由 `BiliAPIClient.favoriteFolders` 映射。
///
/// 只按账户读取（见 SECURITY-MODEL §3）。`list` 为 null 时按空列表处理；`id` 不是正数或缺 `attr` 的行丢弃：缺
/// `attr` 时无法区分私密与默认，宁可不显示也不把它当成公开的默认夹。
struct FavoriteFolderListPayload: Decodable, Sendable {
    let list: [LossyDecodable<FavoriteFolderPayload>]?

    func model() -> [FavoriteFolder] {
        (list ?? []).compactMap { $0.value?.model() }
    }
}

/// 收藏夹列表的一行。
///
/// `attr` 只读两位：bit0 为 1 是私密，bit1 为 0 是默认收藏夹；其余位忽略。
struct FavoriteFolderPayload: Decodable, Sendable {
    let id: Int64?
    let title: String?
    let attr: Int?
    let mediaCount: Int?

    private enum CodingKeys: String, CodingKey {
        case id, title, attr
        case mediaCount = "media_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIfPresent(Int64.self, forKey: .id)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        attr = container.decodeLossyIfPresent(Int.self, forKey: .attr)
        mediaCount = container.decodeLossyIfPresent(Int.self, forKey: .mediaCount)
    }

    func model() -> FavoriteFolder? {
        guard let id, id > 0, let attr else { return nil }
        return FavoriteFolder(
            id: id,
            title: title ?? "",
            mediaCount: max(0, mediaCount ?? 0),
            isPrivate: attr & 1 == 1,
            isDefault: attr & 2 == 0
        )
    }
}

/// 收藏夹内一页（`/x/v3/fav/resource/list`）的 `data`，由 `BiliAPIClient.favoriteFolderPage` 映射为
/// `FavoriteFolderPage`。
///
/// `info` 为 null 说明收藏夹不存在，按 `missingData` 报告。越界页的 `media_count` 为 0、`medias` 为 null，不能用它覆盖
/// 总数：第 1 页之后没有条目而总数为 0 时总数记为未知（nil）。页内条数不足甚至为 0 不代表结束，是否还有下一页取
/// `has_more`。本页条数超过每页条数时整页按解码失败：这样的响应不可能属于所请求的页。
struct FavoriteFolderPagePayload: Decodable, Sendable {
    let info: FavoriteFolderInfoPayload?
    let medias: [FavoriteMediaPayload]?
    let hasMore: Bool?

    private enum CodingKeys: String, CodingKey {
        case info, medias
        case hasMore = "has_more"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try container.decodeIfPresent(FavoriteFolderInfoPayload.self, forKey: .info)
        medias = try container.decodeIfPresent([FavoriteMediaPayload].self, forKey: .medias)
        hasMore = container.decodeLossyBool(forKey: .hasMore)
    }

    func model(pageNumber: Int, pageSize: Int) throws -> FavoriteFolderPage {
        guard let info else { throw BiliAPIError.missingData }
        let rows = medias ?? []
        guard rows.count <= pageSize else { throw BiliAPIError.decodingFailed }
        let items = try rows.compactMap { try $0.model() }
        let mediaCount = max(0, info.mediaCount ?? 0)
        let totalCount: Int? = pageNumber > 1 && rows.isEmpty && mediaCount == 0 ? nil : mediaCount
        return FavoriteFolderPage(
            items: items,
            pageNumber: pageNumber,
            pageSize: pageSize,
            totalCount: totalCount,
            hasMore: hasMore ?? false
        )
    }
}

/// 收藏夹内一页的 `info`：只读当前条件下的条目数。
struct FavoriteFolderInfoPayload: Decodable, Sendable {
    let mediaCount: Int?

    private enum CodingKeys: String, CodingKey {
        case mediaCount = "media_count"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaCount = container.decodeLossyIfPresent(Int.self, forKey: .mediaCount)
    }
}

/// 收藏夹里的一条，映射为 `FavoriteItem`。
///
/// 字段在解码时都按可缺省处理。不可用的条目（判定与先后见 `unavailability`）本来就打不开，接口常给不全：缺标题、
/// 作者、时长或收藏时间时留空由卡片省略，不让整页失败；既没有合规 BVID、条目 ID 也不是正数的行无法成为卡片，丢弃。
/// 可播放的普通视频严格校验：BVID、标题、作者与收藏时间不合规时整页失败。`attr` 的 bit7（仅自己可见）不影响播放，
/// 按普通视频处理。
struct FavoriteMediaPayload: Decodable, Sendable {
    /// 收藏夹条目类型：2 视频、12 音频、21 合集。
    static let videoType = 2
    static let audioType = 12
    static let collectionType = 21
    /// 接口给失效条目的占位标题；有时 `attr` 没有标出失效，只能按标题识别。
    static let invalidTitles: Set<String> = ["已失效视频", "该合集已失效"]

    let id: Int64?
    let type: Int?
    let title: String?
    let cover: String?
    let duration: Int?
    let upper: FavoriteUpperPayload?
    let attr: Int?
    let favoritedAt: Int64?
    let bvid: String?
    let ogv: FavoriteOGVPayload?
    let hasOGV: Bool

    private enum CodingKeys: String, CodingKey {
        case id, type, title, cover, duration, upper, attr, bvid, ogv
        case favoritedAt = "fav_time"
        case legacyBVID = "bv_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyIfPresent(Int64.self, forKey: .id)
        type = container.decodeLossyIfPresent(Int.self, forKey: .type)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        cover = container.decodeLossyIfPresent(String.self, forKey: .cover)
        duration = container.decodeLossyIfPresent(Int.self, forKey: .duration)
        upper = container.decodeLossyIfPresent(FavoriteUpperPayload.self, forKey: .upper)
        attr = container.decodeLossyIfPresent(Int.self, forKey: .attr)
        favoritedAt = container.decodeLossyIfPresent(Int64.self, forKey: .favoritedAt)
        bvid =
            container.decodeLossyIfPresent(String.self, forKey: .bvid)
            ?? container.decodeLossyIfPresent(String.self, forKey: .legacyBVID)
        ogv = container.decodeLossyIfPresent(FavoriteOGVPayload.self, forKey: .ogv)
        // `ogv` 是对象就算番剧／影视，即使里面的字段解不出来；null 或缺失才不是。
        hasOGV = (try? container.decodeNil(forKey: .ogv)) == false
    }

    func model() throws -> FavoriteItem? {
        let validBVID = bvid.flatMap { BVID.isValid($0) ? $0 : nil }
        if let unavailability {
            let fallbackIdentity = id.flatMap { $0 > 0 ? "fav-\(type ?? 0)-\($0)" : nil }
            guard let identity = validBVID ?? fallbackIdentity else { return nil }
            return unavailableModel(id: identity, unavailability: unavailability)
        }
        guard let validBVID,
            let title, !title.isEmpty,
            let upper, let ownerName = upper.name, !ownerName.isEmpty,
            let ownerID = upper.mid, ownerID >= 0,
            let favoritedAt, favoritedAt > 0
        else {
            throw BiliAPIError.decodingFailed
        }
        return FavoriteItem(
            id: validBVID,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            owner: VideoOwner(
                id: ownerID,
                name: ownerName,
                avatarURL: upper.face.flatMap(WebImageURL.parse)
            ),
            durationSeconds: duration.map { max(0, $0) },
            favoritedAt: Date(timeIntervalSince1970: TimeInterval(favoritedAt))
        )
    }

    /// 判定不可用的原因；type 2 的普通视频可以播放，返回 nil。
    ///
    /// 已失效优先：失效的合集或番剧同样打不开，“已失效”比类别更准确；其次番剧与影视（`ogv` 非空，不论 type），
    /// 再按 type 区分合集、音频与其他未知类型。
    var unavailability: LibraryItemUnavailability? {
        if let attr, attr & 1 != 0 {
            return .invalid
        }
        if let title, Self.invalidTitles.contains(title) {
            return .invalid
        }
        if hasOGV {
            return .pgc(label: ogv?.typeName.flatMap { $0.isEmpty ? nil : $0 })
        }
        switch type {
        case Self.videoType:
            return nil
        case Self.collectionType:
            return .collection
        case Self.audioType:
            return .audio
        default:
            return .unsupported
        }
    }

    /// 不可用行的宽松映射：缺失或不合规的标题、作者、时长与收藏时间都留空。
    private func unavailableModel(
        id: String,
        unavailability: LibraryItemUnavailability
    ) -> FavoriteItem {
        let owner: VideoOwner? =
            if let upper, let name = upper.name, !name.isEmpty, let mid = upper.mid, mid >= 0 {
                VideoOwner(id: mid, name: name, avatarURL: upper.face.flatMap(WebImageURL.parse))
            } else {
                nil
            }
        return FavoriteItem(
            id: id,
            title: title.flatMap { $0.isEmpty ? nil : RemoteVideoTitleNormalizer.plainText($0) },
            coverURL: cover.flatMap(WebImageURL.parse),
            owner: owner,
            // 不可用行的时长常为 0 或缺失，都按未知处理、不显示。
            durationSeconds: duration.flatMap { $0 > 0 ? $0 : nil },
            favoritedAt: favoritedAt.flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
            },
            unavailability: unavailability
        )
    }
}

/// 收藏夹条目的 `upper`。
struct FavoriteUpperPayload: Decodable, Sendable {
    let mid: Int64?
    let name: String?
    let face: String?

    private enum CodingKeys: String, CodingKey {
        case mid, name, face
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mid = container.decodeLossyIfPresent(Int64.self, forKey: .mid)
        name = container.decodeLossyIfPresent(String.self, forKey: .name)
        face = container.decodeLossyIfPresent(String.self, forKey: .face)
    }
}

/// 收藏夹条目的 `ogv`（番剧、影视）：只读分类名作为角标原文。
struct FavoriteOGVPayload: Decodable, Sendable {
    let typeName: String?

    private enum CodingKeys: String, CodingKey {
        case typeName = "type_name"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        typeName = container.decodeLossyIfPresent(String.self, forKey: .typeName)
    }
}
