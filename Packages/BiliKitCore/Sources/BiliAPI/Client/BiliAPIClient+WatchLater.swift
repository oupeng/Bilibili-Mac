import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

extension BiliAPIClient {
    public func watchLaterList() async throws -> WatchLaterPage {
        let payload: WatchLaterListPayload = try await get(
            url: try endpoint(
                path: "/x/v2/history/toview/web",
                queryItems: []
            ),
            referer: "https://www.bilibili.com/watchlater/",
            access: .accountRead(
                missingCredential: .fail,
                mapsAuthenticationInvalidation: false
            )
        )
        return try payload.model()
    }

    public func addToWatchLater(bvid: String, aid: Int64? = nil) async throws {
        guard Self.isValidBVID(bvid) || (aid ?? 0) > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var fields = [("bvid", bvid)]
        if let aid, aid > 0 {
            fields.append(("aid", String(aid)))
        }
        let url = try endpoint(path: "/x/v2/history/toview/add", queryItems: [])
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": Self.videoReferer(bvid),
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
        try Self.verifyStatusEnvelope(authorizedResponse.response)
    }

    public func removeFromWatchLater(bvid: String, aid: Int64? = nil) async throws {
        guard Self.isValidBVID(bvid) || (aid ?? 0) > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var fields = [("bvid", bvid)]
        if let aid, aid > 0 {
            fields.append(("aid", String(aid)))
        }
        let url = try endpoint(path: "/x/v2/history/toview/del", queryItems: [])
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                method: .post,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/x-www-form-urlencoded",
                    "Referer": Self.videoReferer(bvid),
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
        try Self.verifyStatusEnvelope(authorizedResponse.response)
    }

    private static func formBody(_ fields: [(String, String)]) throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init(name:value:))
        guard let encoded = components.percentEncodedQuery else {
            throw BiliAPIError.invalidRequest
        }
        return Data(encoded.utf8)
    }

    private static func verifyStatusEnvelope(_ response: HTTPResponse) throws {
        guard response.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        let decoder = JSONDecoder()
        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
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
