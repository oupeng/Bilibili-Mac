import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

extension BiliAPIClient {
    public func watchLater() async throws -> [WatchLaterItem] {
        let payload: WatchLaterPayload = try await get(
            url: try endpoint(
                path: "/x/v2/history/toview"
            ),
            referer: "https://www.bilibili.com/watchlater/",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return try payload.model()
    }

    public func favoriteFolders(mid: Int64) async throws -> [FavoriteFolder] {
        let payload: FavoriteFolderListPayload = try await get(
            url: try endpoint(
                path: "/x/v3/fav/folder/created/list-all",
                queryItems: [
                    URLQueryItem(name: "up_mid", value: String(mid))
                ]
            ),
            referer: "https://space.bilibili.com/\(mid)/favlist",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return payload.model()
    }

    public func favoriteItems(
        folderID: Int64,
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> FavoriteItemsPage {
        let payload: FavoriteItemListPayload = try await get(
            url: try endpoint(
                path: "/x/v3/fav/resource/list",
                queryItems: [
                    URLQueryItem(name: "media_id", value: String(folderID)),
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize)),
                    URLQueryItem(name: "keyword", value: ""),
                    URLQueryItem(name: "order", value: "mtime"),
                    URLQueryItem(name: "type", value: "0"),
                    URLQueryItem(name: "tid", value: "0"),
                    URLQueryItem(name: "platform", value: "web")
                ]
            ),
            referer: "https://space.bilibili.com/",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return try payload.model(page: page)
    }
}
