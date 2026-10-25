import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation

/// 收藏夹卡片的已格式化文字、缩略图地址、可用性与读屏标签，由夹内网格映射为原生卡片（`nativeCard`）。
///
/// 封面右下角是时长（时长为 0 或未知时不显示）；页脚左侧 UP 主名、右侧收藏时间（与资料库其他卡片同一格式，
/// `LibraryCardFormatting.timestamp`）。合集、音频、番剧／影视、未知类型与已失效的条目是不可用卡片，角标与读屏标签写出原因
/// （`LibraryUnavailabilityFormatting`）；缺的字段由卡片省略：没有标题时用占位标题，没有作者时不显示头像与作者名，没有
/// 收藏时间或时长时不显示对应文字，读屏也不读空的部分。作者没有头像地址时不显示头像位。
public struct FavoriteCardPresentation: Sendable, Equatable {
    public let id: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let coverTrailingText: String?
    public let footerLeadingText: String
    public let footerTrailingText: String?
    /// 不可用的原因（角标文字）；可以播放时为 nil。
    public let unavailableReason: String?
    public let accessibilityLabel: String

    public init(item: FavoriteItem, locale: Locale = InterfaceLocale.current) {
        let favoritedAt = item.favoritedAt.map {
            LibraryCardFormatting.timestamp($0, locale: locale)
        }
        let reason = item.unavailability.map {
            LibraryUnavailabilityFormatting.reason($0, locale: locale)
        }
        let title =
            item.title
            ?? LibraryUnavailabilityFormatting.placeholderTitle(item.unavailability, locale: locale)
        let duration = item.durationSeconds.flatMap {
            $0 > 0 ? VideoDurationFormatting.string(seconds: $0, locale: locale) : nil
        }
        id = item.id
        self.title = title
        coverURL = BiliImageThumbnail.url(item.coverURL, size: .videoCover)
        avatarURL = BiliImageThumbnail.url(item.owner?.avatarURL, size: .avatar)
        showsAvatar = item.owner?.avatarURL != nil
        coverTrailingText = duration
        footerLeadingText = item.owner?.name ?? ""
        footerTrailingText = favoritedAt
        unavailableReason = reason
        accessibilityLabel = ListFormatter.localizedString(
            byJoining: [
                title,
                reason,
                item.owner?.name,
                item.durationSeconds.flatMap {
                    $0 > 0 ? VideoCardAccessibilityText.duration(seconds: $0, locale: locale) : nil
                },
                favoritedAt.map {
                    LibraryFeatureStrings.localized("收藏于 \($0)", locale: locale)
                }
            ].compactMap(\.self)
        )
    }

    var nativeCard: NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: title,
            coverURL: coverURL,
            avatarURL: avatarURL,
            showsAvatar: showsAvatar,
            coverTrailingText: coverTrailingText,
            footerLeadingText: footerLeadingText,
            footerTrailingText: footerTrailingText,
            accessibilityLabel: accessibilityLabel,
            availability: unavailableReason.map { .unavailable(badge: $0) } ?? .available
        )
    }
}
