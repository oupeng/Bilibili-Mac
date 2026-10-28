import BiliApplication
import BiliModels

/// 自动连播与列表循环播完后的下一项：先按当前视频的分 P，再按合集里当前所在分部的下一集；纯函数，不读播放器。
///
/// 只在当前分部内前进与回到开头，不跨分部、不进入相关推荐（ROADMAP 界面原则）。当前视频在合集里认不出是哪一集
/// （`PlaybackCollectionEpisodeResolver` 给出 nil）时按没有合集处理。下一集能不能播由调用方判断。
enum PlaybackNextItem: Equatable {
    /// 回到当前分 P 的开头：列表循环时整个列表只有当前这一个分 P。
    case replay
    case page(VideoPage)
    case episode(VideoCollectionEpisode)

    /// 当前分 P 播完后的下一项；`wraps` 为 false 且已是最后一项时为 nil（停下）。
    static func after(
        page currentPage: VideoPage,
        in context: VideoContext,
        episode currentEpisode: VideoCollectionEpisode?,
        wraps: Bool
    ) -> Self? {
        // `context.pages` 由 `VideoUseCase` 按序号排好。
        let pages = context.pages
        if let next = pages.first(where: { $0.index > currentPage.index }) {
            return .page(next)
        }
        // 回到当前视频的第一个分 P；只有一个分 P 时就是从头再播。
        let firstPage: Self =
            pages.first.map { $0.cid == currentPage.cid ? .replay : .page($0) } ?? .replay
        guard let currentEpisode,
            let episodes = context.detail.collection?.sections
                .first(where: { $0.episodes.contains(where: { $0.id == currentEpisode.id }) })?
                .episodes,
            let index = episodes.firstIndex(where: { $0.id == currentEpisode.id })
        else {
            return wraps ? firstPage : nil
        }
        if episodes.indices.contains(index + 1) {
            return .episode(episodes[index + 1])
        }
        guard wraps, let first = episodes.first else { return nil }
        return first.bvid == context.detail.bvid ? firstPage : .episode(first)
    }
}
