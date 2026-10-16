import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// 首页推荐、热门与搜索，以及线路测速用的匿名近期投稿发现。
extension BiliAPIClient {
    public func popular(
        page: Int = 1,
        pageSize: Int = 20
    ) async throws -> PopularPage {
        guard page > 0, (1...50).contains(pageSize) else {
            throw BiliAPIError.invalidRequest
        }
        let payload: PopularPayload = try await get(
            url: try endpoint(
                path: "/x/web-interface/popular",
                queryItems: [
                    URLQueryItem(name: "pn", value: String(page)),
                    URLQueryItem(name: "ps", value: String(pageSize))
                ]
            ),
            referer: "https://www.bilibili.com/",
            access: .accountRead(missingCredential: .useAnonymousRequest)
        )
        let videos = try payload.list.map { try $0.model() }
        return PopularPage(
            videos: videos,
            pageNumber: page,
            pageSize: pageSize,
            hasMore: !payload.noMore
        )
    }

    /// 显式线路测速专用的匿名近期投稿读取；只读取固定日期窗口中的有界元数据。
    func recentSubmissions(
        regionID: Int,
        pageSize: Int,
        dateFrom: String,
        dateTo: String
    ) async throws -> [RecentRankSubmissionPayload] {
        guard regionID > 0, (1...5).contains(pageSize),
            dateFrom.count == 8, dateFrom.allSatisfy(\.isNumber),
            dateTo.count == 8, dateTo.allSatisfy(\.isNumber),
            dateFrom <= dateTo
        else { throw BiliAPIError.invalidRequest }
        let payload: RecentRankPayload = try await get(
            url: try endpoint(
                path: "/x/web-interface/newlist_rank",
                queryItems: [
                    URLQueryItem(name: "main_ver", value: "v3"),
                    URLQueryItem(name: "search_type", value: "video"),
                    URLQueryItem(name: "view_type", value: "hot_rank"),
                    URLQueryItem(name: "copy_right", value: "-1"),
                    URLQueryItem(name: "new_web_tag", value: "1"),
                    URLQueryItem(name: "order", value: "pubdate"),
                    URLQueryItem(name: "cate_id", value: String(regionID)),
                    URLQueryItem(name: "page", value: "1"),
                    URLQueryItem(name: "pagesize", value: String(pageSize)),
                    URLQueryItem(name: "time_from", value: dateFrom),
                    URLQueryItem(name: "time_to", value: dateTo)
                ]
            ),
            referer: "https://www.bilibili.com/"
        )
        return Array((payload.result ?? []).prefix(pageSize))
    }

    /// 测速样本详情：与主详情共用签名请求，只按账户读取，样本必须是当前账户可消费的内容。
    func recentSubmissionDetail(
        for bvid: String
    ) async throws -> RecentSubmissionDetailPayload {
        guard Self.isValidBVID(bvid) else { throw BiliAPIError.invalidRequest }
        return try await signedVideoDetail(
            bvid: bvid,
            access: .accountRead(missingCredential: .fail)
        )
    }

    public func recommendations(
        after continuation: RecommendationContinuation? = nil
    ) async throws -> RecommendationPage {
        let freshIndex = continuation?.freshIndex ?? 1
        guard freshIndex > 0 else {
            throw BiliAPIError.invalidRequest
        }
        let payload: RecommendationPayload = try await signedRequest(
            path: "/x/web-interface/wbi/index/top/feed/rcmd",
            parameters: {
                [
                    "fresh_idx": String(freshIndex),
                    "fresh_idx_1h": String(freshIndex)
                ]
            },
            send: { url in
                try await get(
                    url: url,
                    referer: "https://www.bilibili.com/",
                    access: .accountRead(missingCredential: .useAnonymousRequest)
                )
            }
        )
        let videos = payload.item.compactMap { $0.model() }
        let current = RecommendationContinuation(freshIndex: freshIndex)
        let next =
            freshIndex < Int.max && !videos.isEmpty
            ? RecommendationContinuation(freshIndex: freshIndex + 1)
            : nil
        return RecommendationPage(
            videos: videos,
            continuation: current,
            nextContinuation: next
        )
    }

    public func searchVideos(
        request: VideoSearchRequest
    ) async throws -> SearchPage {
        let criteria = request.criteria
        guard criteria.isValid, request.page > 0 else {
            throw BiliAPIError.invalidRequest
        }
        var parameters = [
            "keyword": criteria.query,
            "page": String(request.page),
            "page_size": String(criteria.pageSize),
            "search_type": "video",
            "order": criteria.order.apiValue,
            "duration": criteria.duration.apiValue
        ]
        if let range = criteria.publicationRange {
            parameters["pubtime_begin_s"] = String(range.beginTimestamp)
            parameters["pubtime_end_s"] = String(range.endTimestamp)
        }
        let payload: SearchPayload = try await signedRequest(
            path: "/x/web-interface/wbi/search/type",
            parameters: { parameters },
            send: { url in
                // 该接口要求 Cookie 含 buvid3；匿名与账户读取两条路径都在授权后附加。
                try await getWithAuthorizationProvenance(
                    url: url,
                    referer: "https://www.bilibili.com/",
                    access: .accountRead(missingCredential: .useAnonymousRequest),
                    additionalCookie: Self.searchBuvid3Cookie
                ).payload
            }
        )
        return try payload.model()
    }
}
