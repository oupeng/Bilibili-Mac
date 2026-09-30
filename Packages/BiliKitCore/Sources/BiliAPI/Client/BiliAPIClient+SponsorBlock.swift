import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

extension BiliAPIClient {
    /// 获取指定视频 (BVID) 的 SponsorBlock 片段。
    /// 默认支持从 `https://bsbsb.top/api/skipSegments` 请求。
    public func sponsorSegments(
        for bvid: String,
        cid: Int64? = nil
    ) async throws -> [SponsorSegment] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }

        var components = URLComponents(string: "https://bsbsb.top/api/skipSegments")!
        var queryItems = [URLQueryItem(name: "videoID", value: bvid)]
        if let cid {
            queryItems.append(URLQueryItem(name: "cid", value: String(cid)))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }

        let baseRequest = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "User-Agent": userAgent,
                "origin": "chrome-extension://eaoelafamejbnggahofapllmfhlhajdd",
                "x-ext-version": "0.5.0"
            ]
        )

        let authorizedResponse: AuthorizedHTTPResponse
        do {
            authorizedResponse = try await response(
                baseRequest: baseRequest,
                access: .anonymous,
                maximumResponseSize: 2 * 1_024 * 1_024
            )
        } catch let error as BiliAPIError {
            if case .httpStatus(let status) = error, status == 404 {
                return []
            }
            throw error
        }

        let response = authorizedResponse.response
        let payloads: [SponsorSegmentPayload]
        do {
            payloads = try decoder.decode([SponsorSegmentPayload].self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }

        return payloads.compactMap { $0.model() }
    }
}
