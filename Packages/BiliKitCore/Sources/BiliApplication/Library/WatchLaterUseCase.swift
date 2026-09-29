import BiliModels

public enum WatchLaterError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

public protocol WatchLaterRepository: Sendable {
    func watchLaterItems() async throws -> [WatchLaterItem]
}

public struct WatchLaterUseCase: Sendable {
    private let repository: WatchLaterRepository

    public init(repository: WatchLaterRepository) {
        self.repository = repository
    }

    public func load() async throws -> [WatchLaterItem] {
        try await repository.watchLaterItems()
    }
}
