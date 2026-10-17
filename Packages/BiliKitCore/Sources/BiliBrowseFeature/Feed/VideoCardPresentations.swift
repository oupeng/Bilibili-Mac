import BiliModels
import BiliUI
import Foundation

public struct PopularVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String
    public let footerText: String
    public let accessibilityLabel: String

    public init(video: PopularVideo, locale: Locale = .current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
        ownerName = video.owner.name
        viewCountText = VideoMetadataFormatting.compactCount(
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt,
            locale: locale
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationText: durationText,
            publishedDateText: publishedDateText,
            locale: locale
        )
    }
}

public struct RecommendedVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String
    public let footerText: String
    public let recommendationReason: String?
    public let accessibilityLabel: String

    public init(video: RecommendedVideo, locale: Locale = .current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
        ownerName = video.owner.name
        viewCountText = VideoMetadataFormatting.compactCount(
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = VideoDurationFormatting.string(
            seconds: video.durationSeconds
        )
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt,
            locale: locale
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        recommendationReason = video.recommendationReason
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationText: durationText,
            publishedDateText: publishedDateText,
            recommendationReason: video.recommendationReason,
            locale: locale
        )
    }
}

public struct SearchVideoCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let ownerName: String
    public let viewCountText: String
    public let danmakuCountText: String
    public let durationText: String?
    public let footerText: String
    public let accessibilityLabel: String

    public init(video: SearchVideo, locale: Locale = .current) {
        bvid = video.bvid
        title = video.title
        coverURL = BiliImageThumbnail.url(video.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(video.owner.avatarURL, size: .avatar)
        ownerName = video.owner.name
        viewCountText = VideoMetadataFormatting.compactCount(
            video.statistics.viewCount,
            locale: locale
        )
        danmakuCountText = VideoMetadataFormatting.compactCount(
            video.statistics.danmakuCount,
            locale: locale
        )
        durationText = video.durationSeconds.map {
            VideoDurationFormatting.string(seconds: $0)
        }
        let publishedDateText = VideoMetadataFormatting.publishedDate(
            video.publishedAt,
            locale: locale
        )
        footerText = "\(video.owner.name) · \(publishedDateText)"
        accessibilityLabel = videoCardAccessibilityLabel(
            title: video.title,
            ownerName: video.owner.name,
            viewCountText: viewCountText,
            danmakuCountText: danmakuCountText,
            durationText: durationText,
            publishedDateText: publishedDateText,
            locale: locale
        )
    }
}

/// 推荐、热门与搜索卡片共用的 VoiceOver 标签：读出卡片上可见的全部信息。
private func videoCardAccessibilityLabel(
    title: String,
    ownerName: String,
    viewCountText: String,
    danmakuCountText: String,
    durationText: String?,
    publishedDateText: String,
    recommendationReason: String? = nil,
    locale: Locale
) -> String {
    ListFormatter.localizedString(
        byJoining: [
            title,
            ownerName,
            BrowseFeatureStrings.localized("播放 \(viewCountText)", locale: locale),
            BrowseFeatureStrings.localized("弹幕 \(danmakuCountText)", locale: locale),
            durationText.map {
                BrowseFeatureStrings.localized("时长 \($0)", locale: locale)
            },
            BrowseFeatureStrings.localized("发布 \(publishedDateText)", locale: locale),
            recommendationReason.map {
                BrowseFeatureStrings.localized("推荐理由 \($0)", locale: locale)
            }
        ].compactMap { $0 }
    )
}
