import BiliModels

public enum WatchLaterError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

public protocol WatchLaterRepository: Sendable {
    func watchLaterList() async throws -> WatchLaterPage
    func addToWatchLater(bvid: String, aid: Int64?) async throws
    func removeFromWatchLater(bvid: String, aid: Int64?) async throws
}
