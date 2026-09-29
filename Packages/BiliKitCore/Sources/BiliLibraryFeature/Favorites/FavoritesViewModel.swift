import BiliApplication
import BiliModels
import Foundation
import Observation

public enum FavoritesFolderItemsState: Sendable, Equatable {
    case idle
    case loading
    case loaded(items: [FavoriteItem], page: Int, hasMore: Bool)
    case loadingMore(items: [FavoriteItem], page: Int)
    case failed(FavoriteError)
}

public enum FavoritesState: Sendable, Equatable {
    case idle
    case loading
    case loadedFolders([FavoriteFolder], selectedFolderID: Int64?)
    case failed(FavoriteError)
}

@MainActor
@Observable
public final class FavoritesViewModel {
    public private(set) var state: FavoritesState = .idle
    public private(set) var itemsState: FavoritesFolderItemsState = .idle

    public var requiresAuthentication: Bool {
        if case .failed(.authenticationRequired) = state { return true }
        if case .failed(.authenticationRequired) = itemsState { return true }
        return false
    }

    public var isBusy: Bool {
        if case .loading = state { return true }
        if case .loading = itemsState { return true }
        if case .loadingMore = itemsState { return true }
        return false
    }

    @ObservationIgnored private let useCase: FavoriteUseCase
    @ObservationIgnored private let loadTask = LatestTask()
    @ObservationIgnored private let loadItemsTask = LatestTask()
    @ObservationIgnored private var currentMID: Int64 = 0

    public init(useCase: FavoriteUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded(mid: Int64) {
        guard state == .idle || currentMID != mid else { return }
        reloadFolders(mid: mid)
    }

    public func reloadFolders(mid: Int64) {
        currentMID = mid
        state = .loading
        itemsState = .idle
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let folders = try await useCase.loadFolders(mid: mid)
                guard isCurrent() else { return }
                let firstFolderID = folders.first?.id
                state = .loadedFolders(folders, selectedFolderID: firstFolderID)
                if let firstFolderID {
                    selectFolder(folderID: firstFolderID)
                }
            } catch {
                guard isCurrent() else { return }
                state = .failed(error as? FavoriteError ?? .transportFailure)
            }
        }
    }

    public func selectFolder(folderID: Int64) {
        if case .loadedFolders(let folders, _) = state {
            state = .loadedFolders(folders, selectedFolderID: folderID)
        }
        itemsState = .loading
        loadItemsTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.loadItems(folderID: folderID, page: 1)
                guard isCurrent() else { return }
                itemsState = .loaded(items: page.items, page: page.pageNumber, hasMore: page.hasMore)
            } catch {
                guard isCurrent() else { return }
                itemsState = .failed(error as? FavoriteError ?? .transportFailure)
            }
        }
    }

    public func loadMoreItems() {
        guard case .loadedFolders(_, let selectedID) = state,
            let folderID = selectedID,
            case .loaded(let items, let currentPage, let hasMore) = itemsState,
            hasMore
        else {
            return
        }
        let nextPage = currentPage + 1
        itemsState = .loadingMore(items: items, page: nextPage)
        loadItemsTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let page = try await useCase.loadItems(folderID: folderID, page: nextPage)
                guard isCurrent() else { return }
                let combined = items + page.items
                itemsState = .loaded(items: combined, page: page.pageNumber, hasMore: page.hasMore)
            } catch {
                guard isCurrent() else { return }
                itemsState = .loaded(items: items, page: currentPage, hasMore: true)
            }
        }
    }

    public func reset() {
        loadTask.cancel()
        loadItemsTask.cancel()
        state = .idle
        itemsState = .idle
        currentMID = 0
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
        await loadItemsTask.wait()
    }
}
