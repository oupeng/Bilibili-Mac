import Foundation

public struct WatchLaterItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let aid: Int64?
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let progressSeconds: Int
    public let durationSeconds: Int
    public let addedAt: Date

    public init(
        bvid: String,
        aid: Int64? = nil,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        progressSeconds: Int,
        durationSeconds: Int,
        addedAt: Date
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.progressSeconds = progressSeconds
        self.durationSeconds = durationSeconds
        self.addedAt = addedAt
    }
}

public struct WatchLaterPage: Sendable, Equatable {
    public let items: [WatchLaterItem]
    public let count: Int

    public init(items: [WatchLaterItem], count: Int) {
        self.items = items
        self.count = count
    }
}
