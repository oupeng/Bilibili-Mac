import BiliModels
import BiliUI
import Foundation

public struct WatchLaterCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let progressText: String
    public let footerLeadingText: String
    public let footerTrailingText: String
    public let accessibilityLabel: String

    public init(item: WatchLaterItem, locale: Locale = .current) {
        let progress = WatchHistoryCardFormatting.progress(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds,
            locale: locale
        )
        bvid = item.bvid
        title = item.title
        coverURL = item.coverURL
        avatarURL = item.owner.avatarURL
        showsAvatar = item.owner.avatarURL != nil
        progressText = progress
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

public struct LoadedWatchLaterContent {
    public let items: [WatchLaterCardPresentation]
    public let count: Int
    public let select: (String) -> Void
    public let remove: (String) -> Void

    public init(
        items: [WatchLaterCardPresentation],
        count: Int,
        select: @escaping (String) -> Void,
        remove: @escaping (String) -> Void
    ) {
        self.items = items
        self.count = count
        self.select = select
        self.remove = remove
    }
}
