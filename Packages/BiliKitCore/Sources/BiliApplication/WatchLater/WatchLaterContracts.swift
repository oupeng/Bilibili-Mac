import BiliModels

/// 稍后再看的一页：条目、本页页码、下一页页码与当前条件下的总条数。
///
/// 下一页由 adapter 按接口给的总条数推出（本页有条目且已请求的条数少于总数），nil 表示没有更多；条数没有
/// 另设上限，内存中的保留上限由 `PagedVideoList` 负责。有筛选或关键词时总条数是筛选后的条数。
public struct WatchLaterPage: Sendable, Equatable {
    public let items: [WatchLaterItem]
    public let pageNumber: Int
    public let nextPageNumber: Int?
    public let totalCount: Int

    public init(items: [WatchLaterItem], pageNumber: Int, nextPageNumber: Int?, totalCount: Int) {
        self.items = items
        self.pageNumber = pageNumber
        self.nextPageNumber = nextPageNumber
        self.totalCount = totalCount
    }
}

/// 稍后再看的认证读取 port；请求带完整条件与从 1 开始的页码。
///
/// 实现是 BiliAPI 的 `BiliWatchLaterRepository`，只经 `WatchLaterUseCase` 调用；只按账户读取，本地无凭据时
/// 失败，不退回匿名请求。Endpoint、凭据与远端错误映射属于具体 adapter，不进入 Application；失败统一抛出
/// `ContentApplicationError`，取消原样传播。
public protocol WatchLaterRepository: Sendable {
    func watchLater(request: WatchLaterRequest) async throws -> WatchLaterPage
}

/// 读取稍后再看的一页，并校验响应属于所请求的页。
public struct WatchLaterUseCase: Sendable {
    /// 稍后再看每页条数；adapter 请求的 `ps`、“是否还有下一页”的推算与加载骨架的本页条数共用这个值。
    ///
    /// 与网页端相同取 20。接口允许的上限未经确认：调大前先核对接口仍按请求的条数返回，否则按总条数推出的
    /// 下一页会与实际错位。
    public static let pageSize = 20

    private let repository: any WatchLaterRepository

    public init(repository: any WatchLaterRepository) {
        self.repository = repository
    }

    /// 页码不是正数或条件不合法时不发请求；响应的页码不是所请求的页、或下一页不是紧接着的一页时按无效响应
    /// 失败，不让错位的页并进列表。
    public func load(_ request: WatchLaterRequest) async throws -> WatchLaterPage {
        guard request.page > 0, request.criteria.isValid else {
            throw ContentApplicationError.invalidRequest
        }
        let result = try await repository.watchLater(request: request)
        guard result.pageNumber == request.page,
            result.nextPageNumber.map({ $0 == request.page + 1 }) ?? true
        else {
            throw ContentApplicationError.invalidResponse
        }
        return result
    }
}
