import BiliModels
import BiliUI
import SwiftUI

public struct LoadedFavoritesContent {
    public let folders: [FavoriteFolder]
    public let selectedFolderID: Int64?
    public let items: [FavoriteCardPresentation]
    public let hasMore: Bool
    public let isLoadingMore: Bool
    public let selectFolder: (Int64) -> Void
    public let loadMore: () -> Void
    public let selectItem: (String) -> Void

    public init(
        folders: [FavoriteFolder],
        selectedFolderID: Int64?,
        items: [FavoriteCardPresentation],
        hasMore: Bool,
        isLoadingMore: Bool,
        selectFolder: @escaping (Int64) -> Void,
        loadMore: @escaping () -> Void,
        selectItem: @escaping (String) -> Void
    ) {
        self.folders = folders
        self.selectedFolderID = selectedFolderID
        self.items = items
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.selectFolder = selectFolder
        self.loadMore = loadMore
        self.selectItem = selectItem
    }
}

public struct FavoritesView<LoadedContent: View>: View {
    private let model: FavoritesViewModel
    private let userMID: Int64
    private let makeLoadedContent: (LoadedFavoritesContent) -> LoadedContent
    private let onSelect: (String) -> Void
    private let onAuthenticationRequired: () -> Void

    public init(
        model: FavoritesViewModel,
        userMID: Int64,
        @ViewBuilder makeLoadedContent: @escaping (LoadedFavoritesContent) -> LoadedContent,
        onSelect: @escaping (String) -> Void,
        onAuthenticationRequired: @escaping () -> Void
    ) {
        self.model = model
        self.userMID = userMID
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
        self.onAuthenticationRequired = onAuthenticationRequired
    }

    public var body: some View {
        FavoritesContentView(
            model: model,
            userMID: userMID,
            makeLoadedContent: makeLoadedContent,
            onSelect: onSelect
        )
        .task {
            model.loadIfNeeded(mid: userMID)
            await model.waitForCurrentTask()
        }
        .onChange(of: model.requiresAuthentication) { _, required in
            if required {
                onAuthenticationRequired()
            }
        }
    }
}

struct FavoritesContentView<LoadedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let model: FavoritesViewModel
    let userMID: Int64
    let makeLoadedContent: (LoadedFavoritesContent) -> LoadedContent
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
            VideoCardGridSkeleton(
                loadingLabel: LibraryFeatureStrings.localized("正在加载收藏夹", locale: locale)
            )
        case .loadedFolders(let folders, let selectedFolderID):
            if folders.isEmpty {
                ContentUnavailableView {
                    Label(
                        LibraryFeatureStrings.localized("暂无收藏夹", locale: locale),
                        systemImage: "star"
                    )
                } description: {
                    Text(LibraryFeatureStrings.localized("你的 B 站账号下没有创建或公开的收藏夹。", locale: locale))
                }
            } else {
                folderItemsView(folders: folders, selectedFolderID: selectedFolderID)
            }
        case .failed:
            ContentUnavailableView {
                Label(
                    LibraryFeatureStrings.localized("无法加载收藏夹", locale: locale),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(LibraryFeatureStrings.localized("请检查网络连接或登录状态。", locale: locale))
            } actions: {
                Button(LibraryFeatureStrings.localized("重试", locale: locale)) {
                    model.reloadFolders(mid: userMID)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func folderItemsView(
        folders: [FavoriteFolder],
        selectedFolderID: Int64?
    ) -> some View {
        let (items, hasMore, isLoadingMore) = currentItemsInfo

        makeLoadedContent(
            LoadedFavoritesContent(
                folders: folders,
                selectedFolderID: selectedFolderID,
                items: items.map { FavoriteCardPresentation(item: $0, locale: locale) },
                hasMore: hasMore,
                isLoadingMore: isLoadingMore,
                selectFolder: { folderID in
                    model.selectFolder(folderID: folderID)
                },
                loadMore: {
                    model.loadMoreItems()
                },
                selectItem: onSelect
            )
        )
    }

    private var currentItemsInfo: ([FavoriteItem], Bool, Bool) {
        switch model.itemsState {
        case .idle, .loading, .failed:
            return ([], false, false)
        case .loaded(let items, _, let hasMore):
            return (items, hasMore, false)
        case .loadingMore(let items, _):
            return (items, true, true)
        }
    }

    private var visualPhase: LoadingVisualPhase {
        switch model.state {
        case .idle, .loading:
            .loading
        case .loadedFolders(let folders, _) where folders.isEmpty:
            .empty
        case .loadedFolders:
            .content
        case .failed:
            .failure
        }
    }
}
