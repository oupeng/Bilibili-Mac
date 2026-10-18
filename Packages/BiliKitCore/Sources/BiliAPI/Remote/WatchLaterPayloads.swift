import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 稍后再看（`/x/v2/history/toview/web`）的 `data`，由 `BiliAPIClient.watchLater` 映射为 `WatchLaterPage`。
///
/// 只按账户读取（见 SECURITY-MODEL §3）。按 BVID 去重交给分页列表 `PagedVideoList`；本页有条目且已请求的条数
/// 少于总条数 `count` 时才有下一页。
struct WatchLaterPayload: Decodable, Sendable {
    let count: Int
    /// 列表为空时接口可能给 null。
    let list: [WatchLaterItemPayload]?

    /// 响应必须属于所请求的页，否则整页按解码失败：条数不超过每页条数，本页有条目时总条数必须多于前面各页的
    /// 条数。
    ///
    /// 总条数为负同样失败。
    func model(pageNumber: Int, pageSize: Int) throws -> WatchLaterPage {
        let rows = list ?? []
        let (precedingCount, precedingOverflow) = (pageNumber - 1)
            .multipliedReportingOverflow(by: pageSize)
        guard count >= 0,
            rows.count <= pageSize,
            !precedingOverflow,
            rows.isEmpty || precedingCount < count
        else {
            throw BiliAPIError.decodingFailed
        }
        let items = try rows.compactMap { try $0.model() }
        let (requestedCount, requestedOverflow) = pageNumber.multipliedReportingOverflow(
            by: pageSize
        )
        let hasNextPage = !rows.isEmpty && !requestedOverflow && requestedCount < count
        return WatchLaterPage(
            items: items,
            pageNumber: pageNumber,
            nextPageNumber: hasNextPage ? pageNumber + 1 : nil,
            totalCount: count
        )
    }
}

/// 稍后再看的一行，映射为 `WatchLaterItem`。
///
/// 字段在解码时都按可缺省处理：`aid <= 0` 或 BVID 不合规的行是没有可用 BVID 的分组占位行，映射时丢弃（返回
/// nil），不让整页失败。其余行的标题、作者、加入时间或时长不合规时整页失败。不可用的判定与先后见 `unavailability`；
/// 只带 `redirect_url` 而不属于这三类的条目按普通视频处理。
struct WatchLaterItemPayload: Decodable, Sendable {
    let aid: Int64?
    let bvid: String?
    let title: String?
    let cover: String?
    let duration: Int?
    let owner: WatchLaterOwnerPayload?
    let progress: Int?
    let addedAt: Int64?
    let state: Int?
    let isPGC: Bool?
    let pgcLabel: String?
    let isPUGV: Bool?

    private enum CodingKeys: String, CodingKey {
        case aid, bvid, title, duration, owner, progress, state
        case cover = "pic"
        case addedAt = "add_at"
        case isPGC = "is_pgc"
        case pgcLabel = "pgc_label"
        case isPUGV = "is_pugv"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aid = container.decodeLossyIfPresent(Int64.self, forKey: .aid)
        bvid = container.decodeLossyIfPresent(String.self, forKey: .bvid)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        cover = container.decodeLossyIfPresent(String.self, forKey: .cover)
        duration = container.decodeLossyIfPresent(Int.self, forKey: .duration)
        owner = container.decodeLossyIfPresent(WatchLaterOwnerPayload.self, forKey: .owner)
        progress = container.decodeLossyIfPresent(Int.self, forKey: .progress)
        addedAt = container.decodeLossyIfPresent(Int64.self, forKey: .addedAt)
        state = container.decodeLossyIfPresent(Int.self, forKey: .state)
        isPGC = container.decodeLossyBool(forKey: .isPGC)
        pgcLabel = container.decodeLossyIfPresent(String.self, forKey: .pgcLabel)
        isPUGV = container.decodeLossyBool(forKey: .isPUGV)
    }

    func model() throws -> WatchLaterItem? {
        guard let aid, aid > 0, let bvid, BiliAPIClient.isValidBVID(bvid) else { return nil }
        guard let title, !title.isEmpty,
            let owner, let ownerName = owner.name, !ownerName.isEmpty,
            let ownerID = owner.mid, ownerID >= 0,
            let addedAt, addedAt > 0,
            let duration, duration >= 0
        else {
            throw BiliAPIError.decodingFailed
        }
        return WatchLaterItem(
            bvid: bvid,
            title: RemoteVideoTitleNormalizer.plainText(title),
            coverURL: cover.flatMap(WebImageURL.parse),
            owner: VideoOwner(
                id: ownerID,
                name: ownerName,
                avatarURL: owner.face.flatMap(WebImageURL.parse)
            ),
            durationSeconds: duration,
            progress: Self.progress(progress, durationSeconds: duration),
            addedAt: Date(timeIntervalSince1970: TimeInterval(addedAt)),
            unavailability: unavailability
        )
    }

    /// 已失效优先：失效的番剧或课程同样无法打开，“已失效”比分类更准确；其次番剧与影视，最后课程。
    ///
    /// 充电专属不算不可用，由播放页处理。
    var unavailability: WatchLaterUnavailability? {
        if let state, state < 0 {
            return .invalid
        }
        let label = pgcLabel.flatMap { $0.isEmpty ? nil : $0 }
        if isPGC == true || label != nil {
            return .pgc(label: label)
        }
        if isPUGV == true {
            return .course
        }
        return nil
    }

    /// `-1` 是已看完；正数是已看到的秒数，截到时长以内（时长未知为 0 时不截）；其余取值按没看过。
    private static func progress(_ value: Int?, durationSeconds: Int) -> WatchLaterProgress {
        guard let value else { return .notStarted }
        if value == -1 {
            return .finished
        }
        guard value > 0 else { return .notStarted }
        return .watched(seconds: durationSeconds > 0 ? min(value, durationSeconds) : value)
    }
}

/// 稍后再看条目的 `owner`。
struct WatchLaterOwnerPayload: Decodable, Sendable {
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
