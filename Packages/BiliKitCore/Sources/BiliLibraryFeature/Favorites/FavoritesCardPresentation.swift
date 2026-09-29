import BiliModels
import BiliUI
import Foundation

public struct FavoritesCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let aid: Int64
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let footerLeadingText: String
    public let footerTrailingText: String
    public let accessibilityLabel: String

    public init(item: FavFolderItem, locale: Locale = .current) {
        bvid = item.bvid
        aid = item.aid
        title = item.title
        coverURL = item.coverURL
        avatarURL = item.owner.avatarURL
        showsAvatar = item.owner.avatarURL != nil
        footerLeadingText = item.owner.name
        footerTrailingText = VideoDurationFormatting.string(seconds: item.durationSeconds, locale: locale)
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                item.title,
                item.owner.name,
                VideoDurationFormatting.string(seconds: item.durationSeconds, locale: locale)
            ]
        )
    }
}

public struct LoadedFavoritesContent {
    public let folders: [FavFolder]
    public let selectedFolderID: Int64
    public let items: [FavoritesCardPresentation]
    public let hasMore: Bool
    public let isLoadingMore: Bool
    public let selectFolder: (Int64) -> Void
    public let loadMore: () -> Void
    public let selectVideo: (String) -> Void

    public init(
        folders: [FavFolder],
        selectedFolderID: Int64,
        items: [FavoritesCardPresentation],
        hasMore: Bool,
        isLoadingMore: Bool,
        selectFolder: @escaping (Int64) -> Void,
        loadMore: @escaping () -> Void,
        selectVideo: @escaping (String) -> Void
    ) {
        self.folders = folders
        self.selectedFolderID = selectedFolderID
        self.items = items
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.selectFolder = selectFolder
        self.loadMore = loadMore
        self.selectVideo = selectVideo
    }
}
