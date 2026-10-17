import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

struct WatchHistoryLoadedSurface: Equatable {
    let items: [WatchHistoryItem]
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let requiresManualLoadMore: Bool
    let loadMoreError: ContentApplicationError?

    init?(state: WatchHistoryState, requiresManualLoadMore: Bool) {
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

/// 已登录时的观看历史主区：按 `WatchHistoryViewModel` 的状态显示骨架、空页、失败页或原生网格，叠加刷新与
/// 分页状态胶囊；凭据失败的说明按模型的账户复核进度区分。
///
/// 不拥有请求、分页与复核（`WatchHistoryViewModel`），滚动位置、回顶请求与图片管线由 `WatchHistoryView`
/// 从 App 窗口转交。
struct WatchHistoryContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let model: WatchHistoryViewModel
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
        if let surface = WatchHistoryLoadedSurface(
            state: model.state,
            requiresManualLoadMore: model.requiresManualLoadMore
        ) {
            historyList(
                items: surface.items,
                canLoadMore: surface.canLoadMore,
                isLoadingMore: surface.isLoadingMore,
                requiresManualLoadMore: surface.requiresManualLoadMore,
                loadMoreError: surface.loadMoreError
            )
        } else {
            switch model.state {
            case .idle, .loading:
                VideoCardGridSkeleton(
                    loadingLabel: LibraryFeatureStrings.localized(
                        "正在加载观看历史",
                        locale: locale
                    )
                )
            case .loaded(_, let continuation, let loadMoreError):
                emptyHistory(
                    canLoadMore: continuation != nil,
                    loadMoreError: loadMoreError
                )
            case .failed(let error):
                failure(error)
            case .loadingMore:
                EmptyView()
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

    private func emptyHistory(
        canLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> some View {
        ContentUnavailableView {
            Label(
                LibraryFeatureStrings.localized("暂无可显示的观看历史", locale: locale),
                systemImage: "clock.arrow.circlepath"
            )
        } description: {
            if let loadMoreError {
                Text(message(for: loadMoreError))
            } else if canLoadMore {
                Text(LibraryFeatureStrings.localized("当前页没有普通视频记录，可以继续检查更早的历史。", locale: locale))
            } else {
                Text(LibraryFeatureStrings.localized("在哔哩哔哩观看过的普通视频会显示在这里。", locale: locale))
            }
        } actions: {
            if canLoadMore, loadMoreError?.isRetryable ?? true {
                Button(LibraryFeatureStrings.localized("加载更早的记录", locale: locale)) {
                    model.loadMore()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func historyList(
        items: [WatchHistoryItem],
        canLoadMore: Bool,
        isLoadingMore: Bool,
        requiresManualLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> some View {
        HistoryNativeGridView(
            content: LoadedHistoryContent(
                items: items.map { WatchHistoryCardPresentation(item: $0, locale: locale) },
                tailState: NativeVideoGridTailState(
                    canLoadMore: canLoadMore && !requiresManualLoadMore,
                    tailIdentity: model.paginationTailIdentity,
                    isLoading: isLoadingMore
                ),
                loadMore: model.loadMore,
                select: onSelect
            ),
            host: gridHost
        )
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            RefreshStatusCapsule(
                isRefreshing: model.isRefreshing,
                refreshingLabel: LibraryFeatureStrings.localized("正在刷新观看历史", locale: locale),
                errorMessage: model.refreshError.map(message(for:))
            )
        }
        .overlay(alignment: .bottom) {
            PaginationStatusOverlay(
                paginationStatus(
                    canLoadMore: canLoadMore,
                    isLoadingMore: isLoadingMore,
                    requiresManualLoadMore: requiresManualLoadMore,
                    loadMoreError: loadMoreError
                )
            )
        }
    }

    private func paginationStatus(
        canLoadMore: Bool,
        isLoadingMore: Bool,
        requiresManualLoadMore: Bool,
        loadMoreError: ContentApplicationError?
    ) -> PaginationStatusOverlay.Status {
        if isLoadingMore {
            return .loadingMore(
                label: LibraryFeatureStrings.localized("正在加载更早的记录…", locale: locale)
            )
        }
        if let loadMoreError {
            let canRetry = canLoadMore && loadMoreError.isRetryable
            return .failed(
                message: message(for: loadMoreError),
                retry: canRetry ? { model.loadMore() } : nil
            )
        }
        if requiresManualLoadMore {
            return .manualLoadMore(
                title: LibraryFeatureStrings.localized("加载更早的记录", locale: locale),
                action: { model.loadMore() }
            )
        }
        return .idle
    }

    private func failure(_ error: ContentApplicationError) -> some View {
        let text = ContentFailureText(
            error: error,
            fallbackTitle: LibraryFeatureStrings.localized("无法加载观看历史", locale: locale),
            revalidation: revalidation,
            locale: locale
        )
        return ContentFailureView(
            title: text.title,
            message: text.message,
            retry: error.isRetryable ? { model.reload() } : nil
        )
    }

    private func message(for error: ContentApplicationError) -> String {
        ContentFailureText.message(for: error, revalidation: revalidation, locale: locale)
    }

    /// 历史页的凭据失败总会请求账户复核：复核进行中说“正在重新确认”，结束仍失败时给静态说明。
    private var revalidation: ContentFailureText.Revalidation {
        model.isAwaitingAuthenticationRevalidation ? .awaiting : .finished
    }
}
