import BiliModels

public struct FavoritesUseCase: Sendable {
    private let repository: any FavoritesRepository

    public init(repository: any FavoritesRepository) {
        self.repository = repository
    }

    public func createdFolders(upMID: Int64, targetAID: Int64? = nil) async throws -> [FavFolder] {
        try await repository.createdFolders(upMID: upMID, targetAID: targetAID)
    }

    public func folderItems(mediaID: Int64, page: Int = 1, pageSize: Int = 20) async throws -> FavFolderPage {
        try await repository.folderItems(mediaID: mediaID, page: page, pageSize: pageSize)
    }

    public func dealFavorites(aid: Int64, addMediaIDs: [Int64], delMediaIDs: [Int64]) async throws {
        try await repository.dealFavorites(aid: aid, addMediaIDs: addMediaIDs, delMediaIDs: delMediaIDs)
    }
}
