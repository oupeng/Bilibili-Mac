import BiliModels
import BiliUI
import Foundation

/// History 拥有格式化和真实 AX 文案；平台 renderer 只消费这些已格式化 slot。
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
        let progress = WatchHistoryCardFormatting.progress(
            progressSeconds: item.progressSeconds,
            durationSeconds: item.durationSeconds,
            locale: locale
        )
        let viewedAt = WatchHistoryCardFormatting.viewedAt(item.viewedAt, locale: locale)
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
}

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

    static func progress(
        progressSeconds: Int,
        durationSeconds: Int,
        locale: Locale = .current
    ) -> String {
        let duration = max(0, durationSeconds)
        let progress = min(max(0, progressSeconds), duration)
        if duration > 0, progress >= duration {
            return LibraryFeatureStrings.localized("已看完", locale: locale)
        }
        return "\(VideoDurationFormatting.string(seconds: progress))/"
            + VideoDurationFormatting.string(seconds: duration)
    }

    static func viewedAt(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = DateDisplayFormatting.formatted(
            date,
            date: .omitted,
            time: .shortened,
            calendar: calendar,
            locale: locale
        )
        switch DateDisplayFormatting.dayRelation(of: date, relativeTo: now, calendar: calendar) {
        case .today:
            return LibraryFeatureStrings.localized("今天 \(time)", locale: locale)
        case .yesterday:
            return LibraryFeatureStrings.localized("昨天 \(time)", locale: locale)
        case .earlier:
            let month = calendar.component(.month, from: date)
            let day = calendar.component(.day, from: date)
            return LibraryFeatureStrings.localized(
                "\(month)月\(day)日 \(time)",
                locale: locale
            )
        }
    }
}
