import BiliApplication
import BiliModels

public struct BiliFavoritesRepository: FavoritesRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func createdFolders(upMID: Int64, targetAID: Int64?) async throws -> [FavFolder] {
        do {
            return try await client.createdFavFolders(upMID: upMID, targetAID: targetAID)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: FavoritesError.transportFailure,
                Self.map
            )
        }
    }

    public func folderItems(mediaID: Int64, page: Int, pageSize: Int) async throws -> FavFolderPage {
        do {
            return try await client.favFolderItems(mediaID: mediaID, page: page, pageSize: pageSize)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: FavoritesError.transportFailure,
                Self.map
            )
        }
    }

    public func dealFavorites(aid: Int64, addMediaIDs: [Int64], delMediaIDs: [Int64]) async throws {
        do {
            try await client.dealFavorites(aid: aid, addMediaIDs: addMediaIDs, delMediaIDs: delMediaIDs)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: FavoritesError.transportFailure,
                Self.map
            )
        }
    }

    private static func map(_ failure: BiliAPIError.Failure) -> FavoritesError {
        switch failure {
        case .authorizationRequired, .authenticationInvalid,
            .authorizationUnavailable, .rejected(code: -101):
            .authenticationRequired
        case .restricted:
            .requestRestricted
        case .rejected(let code):
            .serviceRejected(code: code)
        case .transport, .unexpectedHTTPStatus:
            .transportFailure
        case .invalidRequest, .unsupportedMedia, .noPlayableMedia,
            .invalidResponse:
            .invalidResponse
        }
    }
}
