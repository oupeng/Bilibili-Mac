import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 已登录时收藏夹页面的主区：按 `FavoriteFolderViewModel` 的状态显示骨架、三种空态、失败页或原生网格，叠加刷新胶囊与
/// 底部悬浮页码条（总页数大于 1 时，翻页加载与失败期间也保留）。
///
/// 不拥有请求、翻页与复核（`FavoriteFolderViewModel`）；滚动位置、回顶请求与图片管线由根视图从 App 窗口转交。按页整体
/// 替换，网格不做近尾自动加载（`tailState` 为 `.end`），末行下方为页码条留出 `PageNumberPagerGeometry.reservedHeight`。
/// 回顶由 App 在 `successfulReloadGeneration` 前进时发出。
struct FavoriteFolderContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let model: FavoriteFolderViewModel
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void

    var body: some View {
        ZStack {
            content
                .transition(.opacity)
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: visualPhase
        )
        .overlay(alignment: .bottom) {
            if showsPager {
                PageNumberPager(
                    currentPage: model.currentPage,
                    pageCount: model.pageCount,
                    onShowPage: model.showPage
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedFolderID == nil {
            noSelection
        } else {
            switch model.phase {
            case .idle, .loading:
                VideoCardGridSkeleton(
                    loadingLabel: LibraryFeatureStrings.localized("正在加载收藏夹", locale: locale),
                    expectedItemCount: model.expectedPageItemCount
                )
            case .failed(_, let error):
                failures.view(
                    error,
                    fallbackTitle: LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale),
                    retry: { model.reload() }
                )
            case .loaded(let page, let content) where content.items.isEmpty:
                empty(page: page)
            case .loaded(_, let content):
                grid(content.items)
            }
        }
    }

    private var visualPhase: LoadingVisualPhase {
        guard model.selectedFolderID != nil else { return .empty }
        switch model.phase {
        case .idle, .loading:
            return .loading
        case .failed:
            return .failure
        case .loaded(_, let content):
            return content.items.isEmpty ? .empty : .content
        }
    }

    private var showsPager: Bool {
        model.selectedFolderID != nil && model.pageCount > 1
    }

    /// 还没有选择（换号后等新账户的收藏夹列表）时按列表状态说明：列表在路上显示骨架；列表失败给失败页，重试重读列表
    /// （凭据失败的说明按列表自己的复核进度）；账户 mid 未知只说明、不给重试；其余提示在侧栏选择。
    @ViewBuilder
    private var noSelection: some View {
        switch model.folderList.state {
        case .idle, .loading:
            VideoCardGridSkeleton(
                loadingLabel: LibraryFeatureStrings.localized("正在加载收藏夹", locale: locale)
            )
        case .failed(let error):
            LibraryContentFailure(
                isAwaitingRevalidation: model.folderList.isAwaitingAuthenticationRevalidation,
                locale: locale
            )
            .view(
                error,
                fallbackTitle: LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale),
                retry: { model.folderList.reload() }
            )
        case .accountUnidentified:
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("无法确认当前账户", locale: locale),
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            } description: {
                Text(
                    LibraryFeatureStrings.localized(
                        "重新确认登录状态或重新登录后可查看收藏夹。",
                        locale: locale
                    )
                )
            }
        case .loaded:
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("选择一个收藏夹", locale: locale),
                    systemImage: "folder"
                )
            } description: {
                Text(LibraryFeatureStrings.localized("在侧栏选择要查看的收藏夹。", locale: locale))
            }
        }
    }

    /// 只有一页且是第 1 页时才是整个收藏夹（或当前关键词下）没有内容；还有其他页时只是这一页没有可显示的条目。
    @ViewBuilder
    private func empty(page: Int) -> some View {
        if page == 1, model.pageCount == 1 {
            if model.narrowsResults {
                ContentUnavailableView {
                    Label(
                        LibraryFeatureStrings.localized("没有符合条件的视频", locale: locale),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } description: {
                    Text(LibraryFeatureStrings.localized("试试换一个搜索词。", locale: locale))
                } actions: {
                    Button(
                        LibraryFeatureStrings.localized("清除搜索", locale: locale),
                        action: model.clearSearch
                    )
                }
            } else {
                ContentUnavailableView {
                    Label(
                        LibraryFeatureStrings.localized("这个收藏夹还没有视频", locale: locale),
                        systemImage: "folder"
                    )
                } description: {
                    Text(LibraryFeatureStrings.localized("在哔哩哔哩收藏的视频会显示在这里。", locale: locale))
                }
            }
        } else {
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("本页没有可显示的视频", locale: locale),
                    systemImage: "rectangle.stack"
                )
            } description: {
                Text(LibraryFeatureStrings.localized("可以用底部的页码条翻到其他页。", locale: locale))
            }
        }
    }

    private func grid(_ items: [FavoriteItem]) -> some View {
        NativeVideoGridView(
            items: items.map { FavoriteCardPresentation(item: $0, locale: locale).nativeCard },
            accessibilityLabel: LibraryFeatureStrings.localized("收藏夹视频", locale: locale),
            tailState: .end,
            bottomInset: showsPager ? PageNumberPagerGeometry.reservedHeight : 0,
            host: gridHost,
            onNearEnd: {},
            onSelect: onSelect
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            RefreshStatusCapsule(
                isRefreshing: model.isRefreshing,
                refreshingLabel: LibraryFeatureStrings.localized("正在刷新收藏夹", locale: locale),
                errorMessage: model.refreshError.map(failures.message(for:))
            )
        }
    }

    /// 失败文案按模型的账户复核进度区分（`LibraryContentFailure`）。
    private var failures: LibraryContentFailure {
        LibraryContentFailure(
            isAwaitingRevalidation: model.isAwaitingAuthenticationRevalidation,
            locale: locale
        )
    }
}
