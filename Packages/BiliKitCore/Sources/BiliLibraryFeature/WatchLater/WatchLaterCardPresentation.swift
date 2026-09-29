import BiliModels
import BiliUI
import Foundation

public struct WatchLaterCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let durationText: String
    public let footerLeadingText: String
    public let accessibilityLabel: String

    public init(item: WatchLaterItem, locale: Locale = .current) {
        bvid = item.bvid
        title = item.title
        coverURL = optimizedLibraryImageURL(
            item.coverURL,
            width: 640,
            height: 360
        )
        avatarURL = optimizedLibraryImageURL(
            item.owner.avatarURL,
            width: 96,
            height: 96
        )
        showsAvatar = item.owner.avatarURL != nil
        durationText = VideoDurationFormatting.string(seconds: item.durationSeconds)
        footerLeadingText = item.owner.name
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                item.title,
                item.owner.name,
                VideoDurationFormatting.string(seconds: item.durationSeconds)
            ]
        )
    }
}

private func optimizedLibraryImageURL(
    _ url: URL?,
    width: Int,
    height: Int
) -> URL? {
    guard let url,
        let host = url.host?.lowercased(),
        host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
        url.query == nil,
        url.fragment == nil,
        !url.path.contains("@")
    else {
        return url
    }
    var components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )
    components?.path += "@\(width)w_\(height)h_1c.webp"
    return components?.url ?? url
}
