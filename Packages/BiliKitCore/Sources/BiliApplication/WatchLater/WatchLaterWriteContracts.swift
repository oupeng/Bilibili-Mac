/// 稍后再看的写入 port：把一个视频加入或移出指定账户的稍后再看。
///
/// 实现是 BiliAPI 的 `BiliWatchLaterWriteRepository`，只经 `WatchLaterWriteUseCase` 调用。`accountID` 是窗口账户的 mid，
/// 实现必须把它交给写授权器做账户绑定：本地凭据属于另一个账户时不发出请求。失败统一抛出 `AccountWriteError`，取消原样
/// 传播；不重试、不排队。
public protocol WatchLaterWriteRepository: Sendable {
    func add(_ target: VideoWriteTarget, accountID: Int64) async throws
    func remove(_ target: VideoWriteTarget, accountID: Int64) async throws
}

/// 稍后再看的加入与移除；校验账户后执行写入，成功时给出要分发的效果。
public struct WatchLaterWriteUseCase: Sendable {
    private let repository: any WatchLaterWriteRepository

    public init(repository: any WatchLaterWriteRepository) {
        self.repository = repository
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func add(_ target: VideoWriteTarget, accountID: Int64) async throws -> AccountWriteEffect
    {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.add(target, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .watchLaterAdded(target))
    }

    /// 账户 mid 不是正数时不发请求（`invalidRequest`）。
    public func remove(
        _ target: VideoWriteTarget,
        accountID: Int64
    ) async throws -> AccountWriteEffect {
        guard accountID > 0 else { throw AccountWriteError.invalidRequest }
        try await repository.remove(target, accountID: accountID)
        return AccountWriteEffect(accountID: accountID, change: .watchLaterRemoved(target))
    }
}
