import BiliApplication
import BiliModels

/// 稍后再看页的呈现状态；continuation 是下一页的完整请求（条件加页码）。
public typealias WatchLaterState = LibraryVideoListState<WatchLaterItem, WatchLaterRequest>

/// 稍后再看页的 ViewModel：资料库列表的共用状态机，游标是完整请求；条件由 `WatchLaterSession` 拥有。
public typealias WatchLaterViewModel = LibraryVideoListModel<WatchLaterItem, WatchLaterRequest>

extension LibraryVideoListModel where Item == WatchLaterItem, Cursor == WatchLaterRequest {
    /// 以默认条件的第一页起步；按页码翻页，没有新条目的页即停止：稍后再看没有需要跳过的空页，再请求下一页也不会
    /// 更有进展。
    ///
    /// 下一页沿用本页的条件，总条数随页返回。
    public convenience init(useCase: WatchLaterUseCase) {
        self.init(stallPolicy: .stop, firstPageCursor: WatchLaterRequest(), bvid: \.bvid) {
            request in
            let request = request ?? WatchLaterRequest()
            let result = try await useCase.load(request)
            let next = result.nextPageNumber.map {
                WatchLaterRequest(criteria: request.criteria, page: $0)
            }
            return (VideoListPage(items: result.items, nextCursor: next), result.totalCount)
        }
    }
}
