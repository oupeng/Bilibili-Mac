import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

extension BiliAPIClient {
    public func createdFavFolders(upMID: Int64, targetAID: Int64? = nil) async throws -> [FavFolder] {
        var queryItems = [
            URLQueryItem(name: "up_mid", value: String(upMID))
        ]
        if let targetAID, targetAID > 0 {
            queryItems.append(URLQueryItem(name: "rid", value: String(targetAID)))
        }
        let payload: FavFolderListPayload = try await get(
            url: try endpoint(
                path: "/x/v3/fav/folder/created/list-all",
                queryItems: queryItems
            ),
            referer: "https://space.bilibili.com/\(upMID)/favlist",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return payload.model()
    }

    public func favFolderItems(mediaID: Int64, page: Int = 1, pageSize: Int = 20) async throws -> FavFolderPage {
        guard mediaID > 0, page >= 1, (1...30).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: FavResourceListPayload = try await get(
            url: try endpoint(
                path: "/x/v3/fav/resource/list",
                queryItems: [
                    URLQueryItem(name: "media_id", value: String(mediaID)),
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize)),
                    URLQueryItem(name: "keyword", value: ""),
                    URLQueryItem(name: "order", value: "mtime"),
                    URLQueryItem(name: "type", value: "0")
                ]
            ),
            referer: "https://space.bilibili.com/",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return payload.model(pageNumber: page)
    }

    public func dealFavorites(aid: Int64, addMediaIDs: [Int64], delMediaIDs: [Int64]) async throws {
        guard aid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let addStr = addMediaIDs.map(String.init).joined(separator: ",")
        let delStr = delMediaIDs.map(String.init).joined(separator: ",")
        let fields = [
            ("rid", String(aid)),
            ("type", "2"),
            ("add_media_ids", addStr),
            ("del_media_ids", delStr)
        ]
        let url = try endpoint(path: "/x/v3/fav/resource/deal")
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": "https://www.bilibili.com/",
                    "User-Agent": userAgent
                ],
                body: try Self.formBody(fields)
            ),
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            ),
            maximumResponseSize: 16 * 1024
        )
        try Self.verifyStatusEnvelope(authorizedResponse.response.body)
    }

    private static func formBody(_ fields: [(String, String)]) throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init(name:value:))
        guard let encoded = components.percentEncodedQuery else {
            throw BiliAPIError.invalidRequest
        }
        return Data(encoded.utf8)
    }

    private static func verifyStatusEnvelope(_ body: Data) throws {
        guard body.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        let decoder = JSONDecoder()
        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if status.code == -101 || status.code == -111 {
            throw BiliAPIError.authenticationInvalid
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(code: status.code, message: status.message ?? "")
        }
    }
}
