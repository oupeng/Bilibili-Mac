import Foundation

public struct WatchLaterItem: Identifiable, Sendable, Equatable {
    public var id: String { bvid }

    public let bvid: String
    public let aid: Int64
    public let title: String
    public let coverURL: URL?
    public let owner: VideoOwner
    public let durationSeconds: Int
    public let addedAt: Date
    public let progressSeconds: Int

    public init(
        bvid: String,
        aid: Int64,
        title: String,
        coverURL: URL?,
        owner: VideoOwner,
        durationSeconds: Int,
        addedAt: Date,
        progressSeconds: Int = 0
    ) {
        self.bvid = bvid
        self.aid = aid
        self.title = title
        self.coverURL = coverURL
        self.owner = owner
        self.durationSeconds = durationSeconds
        self.addedAt = addedAt
        self.progressSeconds = progressSeconds
    }
}
