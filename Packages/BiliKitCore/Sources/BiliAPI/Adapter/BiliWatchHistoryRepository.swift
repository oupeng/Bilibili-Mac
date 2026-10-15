import BiliApplication
import BiliModels

public struct BiliWatchHistoryRepository: WatchHistoryRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchHistory(
        after continuation: WatchHistoryContinuation?,
        pageSize: Int
    ) async throws -> WatchHistoryPage {
        do {
            return try await client.watchHistory(
                after: continuation,
                pageSize: pageSize
            )
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }
}
