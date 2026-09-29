import BiliModels

public enum FavoritesError: Error, Sendable, Equatable {
    case authenticationRequired
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case invalidResponse
}

public protocol FavoritesRepository: Sendable {
    func createdFolders(upMID: Int64, targetAID: Int64?) async throws -> [FavFolder]
    func folderItems(mediaID: Int64, page: Int, pageSize: Int) async throws -> FavFolderPage
    func dealFavorites(aid: Int64, addMediaIDs: [Int64], delMediaIDs: [Int64]) async throws
}
