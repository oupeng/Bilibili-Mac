import BiliApplication
import BiliModels

/// 稍后再看页的呈现状态；continuation 是下一页的页码。
public typealias WatchLaterState = LibraryVideoListState<WatchLaterItem, Int>

/// 稍后再看页的 ViewModel：资料库列表的共用状态机，按页码翻页。
public typealias WatchLaterViewModel = LibraryVideoListModel<WatchLaterItem, Int>

extension LibraryVideoListModel where Item == WatchLaterItem, Cursor == Int {
    /// 按页码翻页，没有新条目的页即停止：稍后再看没有需要跳过的空页，再请求下一页也不会更有进展。
    public convenience init(useCase: WatchLaterUseCase) {
        self.init(stallPolicy: .stop, bvid: \.bvid) { page in
            let result = try await useCase.load(page: page ?? 1)
            return VideoListPage(items: result.items, nextCursor: result.nextPageNumber)
        }
    }
}
