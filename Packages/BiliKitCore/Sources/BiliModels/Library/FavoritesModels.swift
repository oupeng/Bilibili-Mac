import Foundation

public struct FavFolder: Identifiable, Sendable, Equatable {
    public var id: Int64 { mediaID }

    public let mediaID: Int64
    public let fid: Int64
    public let mid: Int64
    public let title: String
    public let mediaCount: Int
    public let isFavored: Bool?

    public init(
        mediaID: Int64,
        fid: Int64,
        mid: Int64,
        title: String,
        mediaCount: Int,
        isFavored: Bool? = nil
    ) {
        self.mediaID = mediaID
        self.fid = fid
        self.mid = mid
        self.title = title
        self.mediaCount = mediaCount
        self.isFavored = isFavored
    }
}

public struct FavFolderItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let aid: Int64
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let durationSeconds: Int
    public let playCount: Int64
    public let danmakuCount: Int64
    public let favoredAt: Date

    public init(
        aid: Int64,
        bvid: String,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        durationSeconds: Int,
        playCount: Int64 = 0,
        danmakuCount: Int64 = 0,
        favoredAt: Date
    ) {
        self.aid = aid
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.durationSeconds = durationSeconds
        self.playCount = playCount
        self.danmakuCount = danmakuCount
        self.favoredAt = favoredAt
    }
}

public struct FavFolderPage: Sendable, Equatable {
    public let info: FavFolder?
    public let items: [FavFolderItem]
    public let pageNumber: Int
    public let hasMore: Bool

    public init(
        info: FavFolder?,
        items: [FavFolderItem],
        pageNumber: Int,
        hasMore: Bool
    ) {
        self.info = info
        self.items = items
        self.pageNumber = pageNumber
        self.hasMore = hasMore
    }
}
