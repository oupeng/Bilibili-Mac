import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 字幕目录与弹幕 protobuf 分段；字幕正文由 `BiliSubtitleRepository` 另行读取。
extension BiliAPIClient {
    private static let maximumSubtitleCatalogSize = 1 * 1_024 * 1_024
    private static let maximumDanmakuSegmentSize = 2 * 1_024 * 1_024
    /// 被 HTTP 412 拒绝的弹幕分段再请求一次之前的等待时长。
    ///
    /// 弹幕分段会被间歇风控（游客更常见），稍后通常恢复。与 -403／v_voucher 的换 key 重试同属
    /// `signedRequest` 的一次重试，不叠加。
    static let danmakuRestrictedRetryDelay: Duration = .seconds(2)

    func subtitleResources(
        for identity: PlaybackItemIdentity
    ) async throws -> [SubtitleRemoteTrack] {
        guard Self.isValidBVID(identity.bvid), identity.cid > 0 else {
            throw BiliAPIError.invalidRequest
        }
        guard hasAccountAuthorizer else {
            throw BiliAPIError.authorizationRequired
        }
        let payload: SubtitleCatalogPayload = try await signedRequest(
            path: "/x/player/wbi/v2",
            parameters: {
                [
                    "bvid": identity.bvid,
                    "cid": String(identity.cid)
                ]
            },
            send: { url in
                try await get(
                    url: url,
                    referer: Self.videoReferer(identity.bvid),
                    access: .accountRead(missingCredential: .fail),
                    maximumResponseSize: Self.maximumSubtitleCatalogSize
                )
            }
        )
        return try payload.resources()
    }

    func danmakuSegmentData(
        index: Int,
        for identity: PlaybackItemIdentity
    ) async throws -> Data {
        guard Self.isValidBVID(identity.bvid),
            identity.cid > 0,
            (1...DanmakuSegmentUseCase.maximumSegmentIndex).contains(index)
        else {
            throw BiliAPIError.invalidRequest
        }
        return try await signedRequest(
            path: "/x/v2/dm/wbi/web/seg.so",
            intermittentRestrictionRetryDelay: Self.danmakuRestrictedRetryDelay,
            parameters: {
                [
                    "type": "1",
                    "oid": String(identity.cid),
                    "segment_index": String(index)
                ]
            },
            send: { url in
                try await signedDanmakuSegment(url: url, referer: Self.videoReferer(identity.bvid))
            }
        )
    }

    /// 一次签好的分段请求：protobuf 正文不走 JSON envelope 管线，JSON／HTML 错误体在这里识别。
    private func signedDanmakuSegment(url: URL, referer: String) async throws -> Data {
        let access: RequestAccess =
            hasAccountAuthorizer
            ? .accountRead(missingCredential: .useAnonymousRequest)
            : .anonymous
        let authorizedResponse = try await response(
            baseRequest: HTTPRequest(
                url: url,
                headers: [
                    "Accept": "application/octet-stream",
                    "Referer": referer,
                    "User-Agent": userAgent
                ]
            ),
            access: access,
            maximumResponseSize: Self.maximumDanmakuSegmentSize
        )
        let response = authorizedResponse.response
        guard !response.body.isEmpty else {
            throw BiliAPIError.invalidDanmakuData
        }
        guard Self.looksLikeProtobuf(response) else {
            if Self.isKnownNonProtobufBody(response.body),
                let status = try? decoder.decode(
                    APIStatusEnvelope.self,
                    from: response.body
                )
            {
                if let error = authorizedResponse.authorizationProvenance.notLoggedInError(
                    statusCode: status.code
                ) {
                    throw error
                }
                if status.code != 0 {
                    throw BiliAPIError.apiRejected(
                        code: status.code,
                        message: status.message ?? ""
                    )
                }
            }
            throw BiliAPIError.nonProtobufResponse
        }
        return response.body
    }

    private static func looksLikeProtobuf(_ response: HTTPResponse) -> Bool {
        guard
            let contentType = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased(),
            contentType.contains("application/octet-stream")
        else {
            return false
        }
        return !isKnownNonProtobufBody(response.body)
    }

    private static func isKnownNonProtobufBody(_ body: Data) -> Bool {
        if (try? JSONSerialization.jsonObject(with: body)) != nil {
            return true
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return false
        }
        let normalized =
            text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.hasPrefix("<html")
            || normalized.hasPrefix("<!doctype")
    }
}
