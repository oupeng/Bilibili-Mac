import BiliModels

public enum ContentApplicationError: Error, Sendable, Equatable {
    case invalidRequest
    /// 本地没有登录凭据，而该内容只按账户读取。与凭据失效不同，不应触发账户复核。
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case requestRestricted
    case serviceRejected(code: Int)
    case transportFailure
    case unsupportedMedia
    case playbackUnavailable
    case fullViewingEntitlementRequired
    case invalidResponse
    case unavailable
}

/// 游客 Feed 用例所需的远端列表 port，不暴露 endpoint DTO 或具体网络 client。
public protocol FeedRepository: Sendable {
    func recommendations(
        after continuation: RecommendationContinuation?
    ) async throws -> RecommendationPage
    func popular(page: Int, pageSize: Int) async throws -> PopularPage
    func searchVideos(request: VideoSearchRequest) async throws -> SearchPage
}

/// 游客视频用例所需的详情、分 P 与播放地址 port。
public protocol VideoRepository: Sendable {
    func videoDetail(for bvid: String) async throws -> VideoDetail
    func playback(for bvid: String, cid: Int64) async throws -> VideoPlayback
}

/// 当前视频相关推荐所需的独立匿名只读 port。
public protocol RelatedVideoRepository: Sendable {
    func relatedVideos(to bvid: String) async throws -> [RelatedVideo]
}

/// 搜索页 B 站热搜所需的独立匿名只读 port；结果不因登录账号而变化。
public protocol TrendingSearchRepository: Sendable {
    func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword]
}

/// UP 主空间投稿列表的只读 port；只按账户读取，本地无凭据时失败，不退回匿名请求。
public protocol UploaderVideoRepository: Sendable {
    func uploaderVideos(
        ownerID: Int64,
        order: UploaderVideoOrder,
        page: Int
    ) async throws -> UploaderVideoPage
}

/// 播放页只读 UP 主名片（签名与大会员状态）所需的独立 port；具体账户读取策略由 adapter 隐藏。
public protocol UploaderProfileRepository: Sendable {
    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile
}
