import BiliApplication
import BiliBrowseFeature
import BiliModels

/// 空间层的显示规则：头部下方叠什么提示、页码条是否出现、头部是否显示投稿数。
///
/// 纯逻辑，与界面分开测试；登录入口与空状态都是产品契约。
struct UploaderSpaceSidebarPresentation: Equatable {
    enum Overlay: Equatable {
        case none
        case loading
        case empty
        case signIn
        case failure
    }

    let overlay: Overlay
    let showsPager: Bool
    /// 投稿数未知（首页加载中）或为 0 时不显示。
    let headerTotalCount: Int?

    init(state: UploaderSpaceState, pageCount: Int, totalCount: Int) {
        switch state {
        case .closed:
            overlay = .none
        case .loading:
            overlay = .loading
        case .loaded(let page):
            overlay = page.videos.isEmpty ? .empty : .none
        case .failed(_, .authenticationRequired):
            overlay = .signIn
        case .failed:
            overlay = .failure
        }
        showsPager = pageCount > 1 && state != .closed
        headerTotalCount = totalCount > 0 ? totalCount : nil
    }
}
