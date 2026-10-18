import BiliApplication

/// `WatchLaterRepository` 的 B 站实现：只按账户读取稍后再看，错误经内容域映射。
///
/// 无状态。读取时本地无凭据映射为“需要登录”；它对稍后再看意味着窗口状态过期、同样需要复核，这一判断在
/// Library 的资料库列表 ViewModel（`LibraryVideoListModel`），见 SECURITY-MODEL §3。
public struct BiliWatchLaterRepository: WatchLaterRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage {
        do {
            return try await client.watchLater(request: request)
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }
}
