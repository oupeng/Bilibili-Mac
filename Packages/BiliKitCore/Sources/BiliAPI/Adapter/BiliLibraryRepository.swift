import BiliApplication
import BiliModels

public struct BiliWatchLaterRepository: WatchLaterRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchLaterItems() async throws -> [WatchLaterItem] {
        do {
            return try await client.watchLater()
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchLaterError.transportFailure,
                Self.map
            )
        }
    }

    private static func map(_ failure: BiliAPIError.Failure) -> WatchLaterError {
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

public struct BiliFavoriteRepository: FavoriteRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func favoriteFolders(mid: Int64) async throws -> [FavoriteFolder] {
        do {
            return try await client.favoriteFolders(mid: mid)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: FavoriteError.transportFailure,
                Self.map
            )
        }
    }

    public func favoriteItems(
        folderID: Int64,
        page: Int,
        pageSize: Int
    ) async throws -> FavoriteItemsPage {
        do {
            return try await client.favoriteItems(
                folderID: folderID,
                page: page,
                pageSize: pageSize
            )
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: FavoriteError.transportFailure,
                Self.map
            )
        }
    }

    private static func map(_ failure: BiliAPIError.Failure) -> FavoriteError {
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
