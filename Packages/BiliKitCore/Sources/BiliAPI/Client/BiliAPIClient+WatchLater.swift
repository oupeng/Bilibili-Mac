import BiliApplication
import Foundation

/// 稍后再看读取。列表只属于当前账户，所以只按账户读取，本地无凭据时直接失败（见 SECURITY-MODEL §3）；
/// 只读，不涉及任何写请求。
extension BiliAPIClient {
    /// 按请求的条件读取第 `page` 页（从 1 开始）。
    ///
    /// 参数名与取值来自网页端稍后再看页：`asc` 0 最新加入在前、1 最早在前；`viewed` 0 全部、2 未看完；`key`
    /// 为空表示不按关键词过滤；加入时间与时长只在有筛选时传（`add_time_start`／`add_time_end` 为秒级时间戳，
    /// `arc_min_duration`／`arc_max_duration` 为秒）；`web_location` 是网页端稍后再看页的来源标记。
    public func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage {
        let page = request.page
        let criteria = request.criteria
        guard page > 0, criteria.isValid else {
            throw BiliAPIError.invalidRequest
        }
        var parameters = [
            "pn": String(page),
            "ps": String(WatchLaterUseCase.pageSize),
            "viewed": criteria.progress.apiValue,
            "key": criteria.keyword,
            "asc": criteria.order.apiValue,
            "web_location": "333.881"
        ]
        if let addedTime = criteria.addedTime {
            parameters["add_time_start"] = String(addedTime.startTimestamp)
            parameters["add_time_end"] = String(addedTime.endTimestamp)
        }
        let durationRange = criteria.duration.secondsRange
        if let minimum = durationRange.minimum {
            parameters["arc_min_duration"] = String(minimum)
        }
        if let maximum = durationRange.maximum {
            parameters["arc_max_duration"] = String(maximum)
        }
        let payload: WatchLaterPayload = try await signedRequest(
            path: BiliAccountReadPath.watchLater,
            parameters: { parameters },
            send: { url in
                try await get(
                    url: url,
                    referer: "https://www.bilibili.com/watchlater/",
                    access: .accountRead(missingCredential: .fail)
                )
            }
        )
        return try payload.model(pageNumber: page, pageSize: WatchLaterUseCase.pageSize)
    }
}

extension WatchLaterOrder {
    /// 排序在接口 `asc` 参数里的取值。
    fileprivate var apiValue: String {
        switch self {
        case .newestAdded: "0"
        case .oldestAdded: "1"
        }
    }
}

extension WatchLaterProgressFilter {
    /// 进度筛选在接口 `viewed` 参数里的取值；未看完取网页端使用的 2，不是布尔值 1。
    fileprivate var apiValue: String {
        switch self {
        case .all: "0"
        case .unfinished: "2"
        }
    }
}
