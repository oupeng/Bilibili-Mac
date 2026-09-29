import BiliApplication
import BiliModels
import Foundation
import Observation

public enum FavoritesState: Sendable, Equatable {
    case idle
    case loadingFolders
    case loadedFolders(
        folders: [FavFolder],
        selectedFolderID: Int64,
        items: [FavFolderItem],
        page: Int,
        hasMore: Bool,
        isLoadingItems: Bool,
        itemsError: FavoritesError?
    )
    case failed(FavoritesError)
}

@MainActor
@Observable
public final class FavoritesViewModel {
    public private(set) var state: FavoritesState = .idle
    public private(set) var successfulReloadGeneration: UInt64 = 0

    public var requiresAuthentication: Bool {
        switch state {
        case .failed(.authenticationRequired),
             .loadedFolders(_, _, _, _, _, _, .some(.authenticationRequired)):
            true
        default:
            false
        }
    }

    public var isBusy: Bool {
        switch state {
        case .loadingFolders:
            true
        case .loadedFolders(_, _, _, _, _, let isLoadingItems, _):
            isLoadingItems
        case .idle, .failed:
            false
        }
    }

    @ObservationIgnored private let useCase: FavoritesUseCase
    @ObservationIgnored private let loadTask = LatestTask()

    public init(useCase: FavoritesUseCase) {
        self.useCase = useCase
    }

    public func loadIfNeeded(upMID: Int64) {
        guard state == .idle else { return }
        reload(upMID: upMID)
    }

    public func reload(upMID: Int64) {
        state = .loadingFolders
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let folders = try await useCase.createdFolders(upMID: upMID)
                guard isCurrent() else { return }
                guard let firstFolder = folders.first else {
                    state = .loadedFolders(
                        folders: [],
                        selectedFolderID: 0,
                        items: [],
                        page: 1,
                        hasMore: false,
                        isLoadingItems: false,
                        itemsError: nil
                    )
                    return
                }
                let firstPage = try await useCase.folderItems(mediaID: firstFolder.mediaID, page: 1)
                guard isCurrent() else { return }
                state = .loadedFolders(
                    folders: folders,
                    selectedFolderID: firstFolder.mediaID,
                    items: firstPage.items,
                    page: 1,
                    hasMore: firstPage.hasMore,
                    isLoadingItems: false,
                    itemsError: nil
                )
                successfulReloadGeneration &+= 1
            } catch {
                guard isCurrent() else { return }
                state = .failed(error as? FavoritesError ?? .transportFailure)
            }
        }
    }

    public func selectFolder(mediaID: Int64) {
        guard case .loadedFolders(let folders, let currentID, _, _, _, _, _) = state,
              currentID != mediaID else { return }

        state = .loadedFolders(
            folders: folders,
            selectedFolderID: mediaID,
            items: [],
            page: 1,
            hasMore: false,
            isLoadingItems: true,
            itemsError: nil
        )

        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let pageResult = try await useCase.folderItems(mediaID: mediaID, page: 1)
                guard isCurrent() else { return }
                state = .loadedFolders(
                    folders: folders,
                    selectedFolderID: mediaID,
                    items: pageResult.items,
                    page: 1,
                    hasMore: pageResult.hasMore,
                    isLoadingItems: false,
                    itemsError: nil
                )
            } catch {
                guard isCurrent() else { return }
                state = .loadedFolders(
                    folders: folders,
                    selectedFolderID: mediaID,
                    items: [],
                    page: 1,
                    hasMore: false,
                    isLoadingItems: false,
                    itemsError: error as? FavoritesError ?? .transportFailure
                )
            }
        }
    }

    public func loadMore() {
        guard case .loadedFolders(let folders, let folderID, let items, let page, let hasMore, false, _) = state,
              hasMore else { return }

        let nextPage = page + 1
        state = .loadedFolders(
            folders: folders,
            selectedFolderID: folderID,
            items: items,
            page: page,
            hasMore: hasMore,
            isLoadingItems: true,
            itemsError: nil
        )

        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let pageResult = try await useCase.folderItems(mediaID: folderID, page: nextPage)
                guard isCurrent() else { return }
                state = .loadedFolders(
                    folders: folders,
                    selectedFolderID: folderID,
                    items: items + pageResult.items,
                    page: nextPage,
                    hasMore: pageResult.hasMore,
                    isLoadingItems: false,
                    itemsError: nil
                )
            } catch {
                guard isCurrent() else { return }
                state = .loadedFolders(
                    folders: folders,
                    selectedFolderID: folderID,
                    items: items,
                    page: page,
                    hasMore: hasMore,
                    isLoadingItems: false,
                    itemsError: error as? FavoritesError ?? .transportFailure
                )
            }
        }
    }

    public func reset() {
        loadTask.cancel()
        state = .idle
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }
}
