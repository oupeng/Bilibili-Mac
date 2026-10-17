import BiliVideoCollectionUI

/// `WatchHistoryContentView` 交给本 target 网格包装的已加载卡片与分页／选择意图。
///
/// 分页状态与请求仍由 `WatchHistoryViewModel` 拥有；网格包装只显示条目并回送意图。
struct LoadedHistoryContent {
    let items: [WatchHistoryCardPresentation]
    /// 只有仍有下一页且允许自动加载时才可加载；尾部身份是对 near-end 事件去重的不透明标识，不编码远端
    /// continuation。
    let tailState: NativeVideoGridTailState
    /// 网格接近末尾时调用；同一尾部身份只调用一次。
    let loadMore: () -> Void
    let select: (String) -> Void
}
