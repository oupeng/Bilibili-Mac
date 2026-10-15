import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 视频详情（含分 P）、相关推荐与 UP 主签名。
extension BiliAPIClient {
    public func videoDetail(for bvid: String) async throws -> VideoDetail {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: VideoDetailPayload = try await signedVideoDetail(
            bvid: bvid,
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        let detail = try payload.model()
        guard detail.bvid == bvid else {
            throw BiliAPIError.decodingFailed
        }
        return detail
    }

    /// 视频详情的唯一请求：Web 播放页同款 WBI 签名 endpoint，未签名的 `/view` 对游客稳定返回 HTTP 412。
    ///
    /// 主详情与测速样本共用，各自决定授权方式与解码形状。取 key 与重试期间会话变化则取消，
    /// 不以新会话或匿名身份补发。
    func signedVideoDetail<Payload: Decodable & Sendable>(
        bvid: String,
        access: RequestAccess
    ) async throws -> Payload {
        let sessionEpoch = authenticatedSessionEpoch
        return try await withWBIKeyRefresh { forceKeyRefresh in
            let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            let query = try wbiSigner.sign(
                parameters: ["bvid": bvid],
                keys: keys,
                timestamp: timestampProvider()
            )
            let payload: Payload = try await get(
                url: try endpoint(
                    path: "/x/web-interface/wbi/view",
                    percentEncodedQuery: query
                ),
                referer: Self.videoReferer(bvid),
                access: access
            )
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return payload
        }
    }

    /// 登录增强地读取相关推荐；只有本地明确无凭据时匿名。
    public func relatedVideos(to bvid: String) async throws -> [RelatedVideo] {
        guard Self.isValidBVID(bvid) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: [RelatedVideoPayload] = try await get(
            url: try endpoint(
                path: "/x/web-interface/archive/related",
                queryItems: [URLQueryItem(name: "bvid", value: bvid)]
            ),
            referer: Self.videoReferer(bvid),
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        return try payload.map { try $0.model() }
    }

    /// 登录增强地读取公开 UP 主名片（签名与大会员状态）；不会请求 WBI 签名。
    public func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        guard ownerID > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let path = "/x/web-interface/card"
        let queryItems = [
            URLQueryItem(name: "mid", value: String(ownerID)),
            URLQueryItem(name: "photo", value: "false")
        ]
        let url = try endpoint(path: path, queryItems: queryItems)
        guard
            Self.isExactUploaderCardEndpoint(
                url,
                ownerID: ownerID
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        let payload: UploaderCardDataPayload = try await get(
            url: url,
            referer: "https://space.bilibili.com/",
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        guard payload.card.mid == ownerID else {
            throw BiliAPIError.decodingFailed
        }
        return payload.card.model()
    }

    private static func isExactUploaderCardEndpoint(
        _ url: URL,
        ownerID: Int64
    ) -> Bool {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        return components.scheme == "https"
            && components.host == "api.bilibili.com"
            && components.port == nil
            && components.user == nil
            && components.password == nil
            && components.path == "/x/web-interface/card"
            && components.queryItems == [
                URLQueryItem(name: "mid", value: String(ownerID)),
                URLQueryItem(name: "photo", value: "false")
            ]
    }
}
