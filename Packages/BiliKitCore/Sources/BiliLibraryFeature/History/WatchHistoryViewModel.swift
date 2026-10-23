import BiliApplication
import BiliModels

/// 观看历史页的呈现状态；continuation 是 adapter 生成的不透明游标。
public typealias WatchHistoryState = LibraryVideoListState<
    WatchHistoryItem, WatchHistoryContinuation
>

/// 观看历史页的 ViewModel：资料库列表的共用状态机，按历史的不透明 continuation 翻页。
public typealias WatchHistoryViewModel = LibraryVideoListModel<
    WatchHistoryItem, WatchHistoryContinuation
>

extension LibraryVideoListModel where Item == WatchHistoryItem, Cursor == WatchHistoryContinuation {
    /// 历史空页之后可能还有更早的记录：无进展页保留 continuation，交给用户显式继续；空页跳过在
    /// `WatchHistoryUseCase`。
    ///
    /// 接口不给总数，加载骨架无从按条数收窄，所以不传每页条数。
    public convenience init(useCase: WatchHistoryUseCase) {
        self.init(
            stallPolicy: .requireManualContinue,
            pageSize: nil,
            bvid: \.bvid
        ) { continuation in
            let page = try await useCase.load(after: continuation)
            return (VideoListPage(items: page.items, nextCursor: page.continuation), nil)
        }
    }
}
