/// 评论短链解析的窗口级 owner：同一时间只解析一个。
///
/// 新的点击、评论所属视频变化或关窗都取消上一个；取消后的结果即使返回也不再打开。
@MainActor
final class CommentShortLinkResolution {
    private var task: Task<Void, Never>?

    /// 解析出路由后在主线程交给 `open`；解析不出时交给 `open` 的是 nil，由调用方决定回退。
    func start(
        _ resolve: @escaping @Sendable () async -> CommentLinkRoute?,
        open: @escaping @MainActor (CommentLinkRoute?) -> Void
    ) {
        task?.cancel()
        task = Task { [weak self] in
            let route = await resolve()
            guard !Task.isCancelled else { return }
            self?.task = nil
            open(route)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
