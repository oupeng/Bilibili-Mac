import BiliApplication
import BiliModels

/// `WatchHistoryRepository` 的 B 站实现：只按账户读取观看历史，错误经内容域映射。
///
/// 无状态。读取时本地无凭据映射为“需要登录”；它对历史意味着窗口状态过期、同样需要复核，这一判断在
/// 观看历史 ViewModel，见 SECURITY-MODEL §3。
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
