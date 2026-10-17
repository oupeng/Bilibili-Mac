import BiliVideoCollectionUI

/// Feed 视图交给本 target 网格包装（推荐、热门、搜索）的已加载条目与分页／选择意图。
///
/// 分页状态与请求仍由 `BrowseViewModel` 拥有；网格包装只显示条目并回送意图。
struct LoadedFeedContent<Item> {
    let items: [Item]
    let tailState: NativeVideoGridTailState
    /// 仍有下一页时网格接近末尾调用；同一尾部身份只调用一次。
    let loadMore: () -> Void
    let select: (String) -> Void
}

extension FeedPaginationPresentation {
    /// 网格的分页尾部：尾部身份是对 near-end 事件去重的不透明标识，不编码远端 continuation。
    var gridTailState: NativeVideoGridTailState {
        NativeVideoGridTailState(
            canLoadMore: canLoadMore,
            tailIdentity: tailIdentity,
            isLoading: isLoadingMore
        )
    }
}
