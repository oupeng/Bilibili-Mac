import BiliApplication
import BiliUI
import Foundation

extension FeedPaginationPresentation {
    /// 推荐、热门与搜索底部分页胶囊的状态：加载中优先，其次是加载更多失败；失败可重试才给重试。
    func overlayStatus(
        loadingMoreLabel: String,
        locale: Locale,
        retry: @escaping () -> Void
    ) -> PaginationStatusOverlay.Status {
        if isLoadingMore {
            return .loadingMore(label: loadingMoreLabel)
        }
        if let loadMoreError {
            return .failed(
                message: ContentFailureText.message(for: loadMoreError, locale: locale),
                retry: loadMoreError.isRetryable ? retry : nil
            )
        }
        return .idle
    }
}
