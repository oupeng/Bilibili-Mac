import BiliApplication

/// `FavoritesWriteRepository` 的 B 站实现：转调窗口主 API 的收藏写入，并把远端失败映射为 `AccountWriteError`。
///
/// 无状态；底层 client 必须注入了账户写授权器（`LiveAPIClients.main`），否则一律按“需要登录”失败。取消原样传播。
/// 共同的映射在 `AccountWriteErrorMapping`，这里只给出收藏接口的业务码。
public struct BiliFavoritesWriteRepository: FavoritesWriteRepository {
    /// 收藏夹已满。
    ///
    /// 出处是接口文档（记在收藏网关版下）与网页端错误码表，未经本项目实测。
    private static let folderFullCode = 11_203
    // 11201（已经收藏过）、11202（已经取消收藏）没有专门映射：面板每次打开都重读归属，正常操作碰不到；碰到说明归属在
    // 别处变过，按普通业务拒绝显示错误码，不当作成功，让用户重新打开面板看到真实状态。

    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func update(_ change: FavoriteMembershipChange, accountID: Int64) async throws {
        do {
            try await client.updateFavoriteMembership(
                bvid: change.target.bvid,
                adding: change.addedFolderIDs,
                removing: change.removedFolderIDs,
                accountID: accountID
            )
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    public func remove(_ entry: FavoriteFolderEntry, accountID: Int64) async throws {
        do {
            try await client.removeFromFavoriteFolder(
                aid: entry.videoAID,
                folderID: entry.folderID,
                accountID: accountID
            )
        } catch {
            throw Self.accountWriteError(for: error)
        }
    }

    private static func accountWriteError(for error: any Error) -> any Error {
        AccountWriteErrorMapping.error(for: error) { code in
            switch code {
            case folderFullCode: .listFull
            case BiliAPIClient.favoriteFolderMissingCode: .contentUnavailable
            default: nil
            }
        }
    }
}
