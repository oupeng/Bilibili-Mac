import BiliApplication
import BiliModels

/// `FavoritesRepository` 的 B 站实现：只按账户读取收藏夹列表与夹内的页，错误经内容域映射。
///
/// 无状态。夹内读取另有两处收藏夹专属的映射，其余与内容域相同：收藏夹不存在（`data`／`info` 为 null 的
/// `missingData`、业务码 11010）为“内容不存在”，由 Library 重新读取收藏夹列表并回落选择；业务码 -403（访问自己的
/// 收藏夹不应被拒绝，被拒说明登录状态已悄悄失效）按凭据失效报告、交给窗口复核，而不是像其他接口那样当作风控。
public struct BiliFavoritesRepository: FavoritesRepository {
    private let client: BiliAPIClient

    public init(client: BiliAPIClient) {
        self.client = client
    }

    public func favoriteFolders(ownerID: Int64) async throws -> [FavoriteFolder] {
        do {
            return try await client.favoriteFolders(ownerID: ownerID)
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }

    public func favoriteFolderPage(
        request: FavoriteFolderRequest
    ) async throws -> FavoriteFolderPage {
        do {
            return try await client.favoriteFolderPage(request: request)
        } catch BiliAPIError.missingData {
            throw ContentApplicationError.contentUnavailable
        } catch BiliAPIError.apiRejected(let code, _)
            where code == BiliAPIClient.favoriteFolderMissingCode
        {
            throw ContentApplicationError.contentUnavailable
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            throw ContentApplicationError.authenticationInvalid
        } catch {
            throw BiliAPIError.contentApplicationError(for: error)
        }
    }
}
