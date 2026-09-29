import BiliModels

public enum FavoriteError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

public protocol FavoriteRepository: Sendable {
    func favoriteFolders(mid: Int64) async throws -> [FavoriteFolder]
    func favoriteItems(folderID: Int64, page: Int, pageSize: Int) async throws -> FavoriteItemsPage
}

public struct FavoriteUseCase: Sendable {
    private let repository: FavoriteRepository

    public init(repository: FavoriteRepository) {
        self.repository = repository
    }

    public func loadFolders(mid: Int64) async throws -> [FavoriteFolder] {
        try await repository.favoriteFolders(mid: mid)
    }

    public func loadItems(folderID: Int64, page: Int, pageSize: Int = 20) async throws -> FavoriteItemsPage {
        try await repository.favoriteItems(folderID: folderID, page: page, pageSize: pageSize)
    }
}
