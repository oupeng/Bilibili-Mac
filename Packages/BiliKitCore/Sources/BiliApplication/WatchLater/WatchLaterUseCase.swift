import BiliModels

public struct WatchLaterUseCase: Sendable {
    private let repository: any WatchLaterRepository

    public init(repository: any WatchLaterRepository) {
        self.repository = repository
    }

    public func load() async throws -> WatchLaterPage {
        try await repository.watchLaterList()
    }

    public func add(bvid: String, aid: Int64? = nil) async throws {
        try await repository.addToWatchLater(bvid: bvid, aid: aid)
    }

    public func remove(bvid: String, aid: Int64? = nil) async throws {
        try await repository.removeFromWatchLater(bvid: bvid, aid: aid)
    }
}
