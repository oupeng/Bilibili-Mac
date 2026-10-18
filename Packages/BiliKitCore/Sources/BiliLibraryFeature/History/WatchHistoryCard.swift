import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation

/// 观看历史卡片的已格式化文字、缩略图地址与读屏标签，由列表网格映射为原生卡片（`nativeCard`）。
///
/// 进度、观看时间与设备文案在这里格式化，渲染侧只消费这些文字；作者没有头像地址时不显示头像位。
public struct WatchHistoryCardPresentation: Sendable, Equatable {
    public let bvid: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let progressText: String
    public let footerLeadingText: String
    public let footerTrailingText: String
    /// 日期前的观看设备图标（SF Symbol 名）；设备未知时为 nil。
    public let footerTrailingSymbolName: String?
    public let accessibilityLabel: String

    public init(item: WatchHistoryItem, locale: Locale = .current) {
        let progress = LibraryCardFormatting.progress(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds,
            locale: locale
        )
        let viewedAt = LibraryCardFormatting.timestamp(item.viewedAt, locale: locale)
        bvid = item.bvid
        title = item.title
        coverURL = BiliImageThumbnail.url(item.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(item.owner.avatarURL, size: .avatar)
        showsAvatar = item.owner.avatarURL != nil
        progressText = progress
        footerLeadingText = item.owner.name
        footerTrailingText = viewedAt
        footerTrailingSymbolName = item.device.map(WatchHistoryCardFormatting.symbolName)
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                item.title,
                item.owner.name,
                LibraryFeatureStrings.localized("观看进度 \(progress)", locale: locale),
                viewedAt
            ]
                + [item.device.map { WatchHistoryCardFormatting.deviceLabel($0, locale: locale) }]
                .compactMap(\.self)
        )
    }

    var nativeCard: NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: bvid,
            title: title,
            coverURL: coverURL,
            avatarURL: avatarURL,
            showsAvatar: showsAvatar,
            coverTrailingText: progressText,
            footerLeadingText: footerLeadingText,
            footerTrailingText: footerTrailingText,
            footerTrailingSymbolName: footerTrailingSymbolName,
            accessibilityLabel: accessibilityLabel
        )
    }
}

/// 观看历史卡片特有的文字规则：观看设备的图标与读屏说明；进度与观看时间见 `LibraryCardFormatting`。
enum WatchHistoryCardFormatting {
    static func symbolName(_ device: WatchHistoryDevice) -> String {
        switch device {
        case .phone: "smartphone"
        case .pad: "ipad"
        case .web: "desktopcomputer"
        case .tv: "tv"
        }
    }

    static func deviceLabel(_ device: WatchHistoryDevice, locale: Locale = .current) -> String {
        switch device {
        case .phone: LibraryFeatureStrings.localized("在手机上观看", locale: locale)
        case .pad: LibraryFeatureStrings.localized("在平板上观看", locale: locale)
        case .web: LibraryFeatureStrings.localized("在网页上观看", locale: locale)
        case .tv: LibraryFeatureStrings.localized("在电视上观看", locale: locale)
        }
    }
}
