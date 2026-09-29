import Foundation

public struct FavoriteFolder: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let title: String
    public let mediaCount: Int
    public let coverURL: URL?

    public init(
        id: Int64,
        title: String,
        mediaCount: Int,
        coverURL: URL?
    ) {
        self.id = id
        self.title = title
        self.mediaCount = mediaCount
        self.coverURL = coverURL
    }
}

public struct FavoriteItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let aid: Int64
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let durationSeconds: Int
    public let favoriteAt: Date

    public init(
        bvid: String,
        aid: Int64,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        durationSeconds: Int,
        favoriteAt: Date
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.durationSeconds = durationSeconds
        self.favoriteAt = favoriteAt
    }
}

public struct FavoriteItemsPage: Sendable, Equatable {
    public let items: [FavoriteItem]
    public let pageNumber: Int
    public let hasMore: Bool

    public init(
        items: [FavoriteItem],
        pageNumber: Int,
        hasMore: Bool
    ) {
        self.items = items
        self.pageNumber = pageNumber
        self.hasMore = hasMore
    }
}
