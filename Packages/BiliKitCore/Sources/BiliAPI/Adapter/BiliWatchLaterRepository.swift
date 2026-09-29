import BiliApplication
import BiliModels

public struct BiliWatchLaterRepository: WatchLaterRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchLaterList() async throws -> WatchLaterPage {
        do {
            return try await client.watchLaterList()
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchLaterError.transportFailure,
                Self.map
            )
        }
    }

    public func addToWatchLater(bvid: String, aid: Int64?) async throws {
        do {
            try await client.addToWatchLater(bvid: bvid, aid: aid)
        } catch {
            throw BiliAPIError.domainError(
                for: error,
                fallback: WatchLaterError.transportFailure,
                Self.map
            )
        }
    }

    public func removeFromWatchLater(bvid: String, aid: Int64?) async throws {
        do {
            try await client.removeFromWatchLater(bvid: bvid, aid: aid)
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
