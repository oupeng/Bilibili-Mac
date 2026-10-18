import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 资料库列表页的来源文案，由来源的根视图按当前 locale 本地化后交给共用视图。
struct LibraryVideoListText {
    /// 显式继续策略的来源（观看历史）空页之后的文案。
    struct ManualContinue {
        /// 当前页没有可显示条目、但还能继续时的空态说明。
        let emptyDescription: String
        /// 显式继续按钮的标题。
        let actionTitle: String
    }

    let signInTitle: String
    let signInDescription: String
    let loading: String
    let emptyTitle: String
    let emptySymbol: String
    let emptyDescription: String
    let failureTitle: String
    let refreshing: String
    let loadingMore: String
    let gridAccessibilityLabel: String
    /// 只有显式继续策略的来源给出；停止策略的来源没有显式继续入口。
    let manualContinue: ManualContinue?
}

/// 网格的输入：从列表状态取出条目与分页状态。
///
/// 没有条目的 `loaded`、加载中与失败时构造失败，由空页、骨架或失败页接手；加载更多期间总能构造。
struct LibraryVideoListLoadedSurface<Item: Sendable & Equatable, Cursor: Equatable & Sendable>:
    Equatable
{
    let items: [Item]
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let requiresManualLoadMore: Bool
    let loadMoreError: ContentApplicationError?

    init?(state: LibraryVideoListState<Item, Cursor>, requiresManualLoadMore: Bool) {
        switch state {
        case .loaded(let items, let continuation, let loadMoreError)
        where !items.isEmpty:
            self.items = items
            canLoadMore = continuation != nil
            isLoadingMore = false
            self.requiresManualLoadMore = requiresManualLoadMore
            self.loadMoreError = loadMoreError
        case .loadingMore(let items, _):
            self.items = items
            canLoadMore = true
            isLoadingMore = true
            self.requiresManualLoadMore = false
            loadMoreError = nil
        case .idle, .loading, .loaded, .failed:
            return nil
        }
    }
}

/// 已登录时的资料库列表主区：按 `LibraryVideoListModel` 的状态显示骨架、空页、失败页或原生网格，叠加刷新与
/// 分页状态胶囊；凭据失败的说明按模型的账户复核进度区分。
///
/// 不拥有请求、分页与复核（`LibraryVideoListModel`）；条目到卡片的映射由来源给出，滚动位置、回顶请求与图片
/// 管线由根视图从 App 窗口转交。
struct LibraryVideoListContentView<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let model: LibraryVideoListModel<Item, Cursor>
    let text: LibraryVideoListText
    let card: (Item, Locale) -> NativeVideoCardPresentation
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
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VideoCardGridSkeleton(loadingLabel: text.loading)
        case .loaded(let items, let continuation, let loadMoreError) where items.isEmpty:
            emptyList(
                canLoadMore: continuation != nil,
                loadMoreError: loadMoreError
            )
        case .failed(let error):
            failure(error)
        case .loaded, .loadingMore:
            // 有条目的 loaded 与加载更多共用这一支，网格在加载更多前后保持同一视图身份；
            // 这两种状态下 surface 总能构造。
            if let surface = LibraryVideoListLoadedSurface(
                state: model.state,
                requiresManualLoadMore: model.requiresManualLoadMore
            ) {
                videoList(surface)
            }
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loaded(let items, _, _) where items.isEmpty:
            .empty
        case .loaded, .loadingMore:
            .content
        case .failed:
            .failure
        }
    }

    private func emptyList(
        canLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> some View {
        ContentUnavailableView {
            Label(text.emptyTitle, systemImage: text.emptySymbol)
        } description: {
            if let loadMoreError {
                Text(message(for: loadMoreError))
            } else if canLoadMore, let manualContinue = text.manualContinue {
                Text(manualContinue.emptyDescription)
            } else {
                Text(text.emptyDescription)
            }
        } actions: {
            if canLoadMore, loadMoreError?.isRetryable ?? true,
                let manualContinue = text.manualContinue
            {
                Button(manualContinue.actionTitle) {
                    model.loadMore()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func videoList(
        _ surface: LibraryVideoListLoadedSurface<Item, Cursor>
    ) -> some View {
        NativeVideoGridView(
            items: surface.items.map { card($0, locale) },
            accessibilityLabel: text.gridAccessibilityLabel,
            // 尾标只在可自动加载时存在：显式继续门、加载更多失败与原地刷新都暂停近尾触发。
            tailState: NativeVideoGridTailState(
                canLoadMore: model.paginationTailIdentity != nil,
                tailIdentity: model.paginationTailIdentity,
                isLoading: surface.isLoadingMore
            ),
            host: gridHost,
            onNearEnd: model.loadMore,
            onSelect: onSelect
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            RefreshStatusCapsule(
                isRefreshing: model.isRefreshing,
                refreshingLabel: text.refreshing,
                errorMessage: model.refreshError.map(message(for:))
            )
        }
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(paginationStatus(surface))
        }
    }

    private func paginationStatus(
        _ surface: LibraryVideoListLoadedSurface<Item, Cursor>
    ) -> PaginationStatusOverlay.Status {
        if surface.isLoadingMore {
            return .loadingMore(label: text.loadingMore)
        }
        if let loadMoreError = surface.loadMoreError {
            let canRetry = surface.canLoadMore && loadMoreError.isRetryable
            return .failed(
                message: message(for: loadMoreError),
                retry: canRetry ? { model.loadMore() } : nil
            )
        }
        if surface.requiresManualLoadMore, let manualContinue = text.manualContinue {
            return .manualLoadMore(
                title: manualContinue.actionTitle,
                action: { model.loadMore() }
            )
        }
        return .idle
    }

    private func failure(_ error: ContentApplicationError) -> some View {
        let failureText = ContentFailureText(
            error: error,
            fallbackTitle: text.failureTitle,
            revalidation: revalidation,
            locale: locale
        )
        return ContentFailureView(
            title: failureText.title,
            message: failureText.message,
            retry: error.isRetryable ? { model.reload() } : nil
        )
    }

    private func message(for error: ContentApplicationError) -> String {
        ContentFailureText.message(for: error, revalidation: revalidation, locale: locale)
    }

    /// 资料库列表的凭据失败总会请求账户复核：复核进行中说“正在重新确认”，结束仍失败时给静态说明。
    private var revalidation: ContentFailureText.Revalidation {
        model.isAwaitingAuthenticationRevalidation ? .awaiting : .finished
    }
}
