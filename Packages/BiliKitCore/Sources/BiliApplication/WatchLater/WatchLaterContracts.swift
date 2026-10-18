import BiliModels

/// 稍后再看的一页：条目、本页页码与下一页页码。
///
/// 下一页由 adapter 按接口给的总条数推出（本页有条目且已请求的条数少于总数），nil 表示没有更多；条数没有
/// 另设上限，内存中的保留上限由 `PagedVideoList` 负责。
public struct WatchLaterPage: Sendable, Equatable {
    public let items: [WatchLaterItem]
    public let pageNumber: Int
    public let nextPageNumber: Int?

    public init(items: [WatchLaterItem], pageNumber: Int, nextPageNumber: Int?) {
        self.items = items
        self.pageNumber = pageNumber
        self.nextPageNumber = nextPageNumber
    }
}

/// 稍后再看的认证读取 port；页码从 1 开始。
///
/// 实现是 BiliAPI 的 `BiliWatchLaterRepository`，只经 `WatchLaterUseCase` 调用；只按账户读取，本地无凭据时
/// 失败，不退回匿名请求。Endpoint、凭据与远端错误映射属于具体 adapter，不进入 Application；失败统一抛出
/// `ContentApplicationError`，取消原样传播。
public protocol WatchLaterRepository: Sendable {
    func watchLater(page: Int) async throws -> WatchLaterPage
}

/// 读取稍后再看的一页，并校验响应属于所请求的页。
public struct WatchLaterUseCase: Sendable {
    private let repository: any WatchLaterRepository

    public init(repository: any WatchLaterRepository) {
        self.repository = repository
    }

    /// 页码不是正数时不发请求；响应的页码不是所请求的页、或下一页不是紧接着的一页时按无效响应失败，
    /// 不让错位的页并进列表。
    public func load(page: Int = 1) async throws -> WatchLaterPage {
        guard page > 0 else {
            throw ContentApplicationError.invalidRequest
        }
        let result = try await repository.watchLater(page: page)
        guard result.pageNumber == page,
            result.nextPageNumber.map({ $0 == page + 1 }) ?? true
        else {
            throw ContentApplicationError.invalidResponse
        }
        return result
    }
}
