import BiliApplication
import BiliModels
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliLibraryFeature

/// 稍后再看卡片：封面右下角按进度显示“已看完”、进度或时长，页脚是 UP 主与加入时间；番剧／影视、课程与失效
/// 是不可用卡片，角标与读屏标签写出原因。
struct WatchLaterCardFormattingTests {
    @Test(arguments: [
        (WatchLaterProgress.finished, completedText),
        (.watched(seconds: 65), "1:05/10:00"),
        (.notStarted, "10:00")
    ])
    func coverTextFollowsTheProgress(progress: WatchLaterProgress, expected: String) {
        let presentation = WatchLaterCardPresentation(
            item: item(progress: progress),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.coverTrailingText == expected)
        #expect(presentation.nativeCard.coverTrailingText == expected)
    }

    @Test
    func footerShowsTheUploaderAndTheAddedTime() {
        let locale = Locale(identifier: "zh-Hans")
        let item = item(progress: .notStarted)
        let presentation = WatchLaterCardPresentation(item: item, locale: locale)

        #expect(presentation.footerLeadingText == "稍后作者")
        #expect(
            presentation.footerTrailingText
                == LibraryCardFormatting.timestamp(item.addedAt, locale: locale)
        )
        #expect(presentation.nativeCard.isActivatable)
    }

    @Test(arguments: [
        (WatchLaterUnavailability.pgc(label: "电影"), "电影"),
        (.pgc(label: nil), localized("番剧")),
        (.course, localized("课程")),
        (.invalid, localized("已失效"))
    ])
    func unavailableItemsShowTheReason(unavailability: WatchLaterUnavailability, reason: String) {
        let presentation = WatchLaterCardPresentation(
            item: item(progress: .notStarted, unavailability: unavailability),
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(presentation.unavailableReason == reason)
        #expect(presentation.nativeCard.availability == .unavailable(badge: reason))
        #expect(!presentation.nativeCard.isActivatable)
        #expect(presentation.accessibilityLabel.contains(reason))
    }

    private func item(
        progress: WatchLaterProgress,
        unavailability: WatchLaterUnavailability? = nil
    ) -> WatchLaterItem {
        WatchLaterItem(
            bvid: "BV1LaterCard",
            title: "稍后再看卡片",
            coverURL: nil,
            owner: VideoOwner(id: 7, name: "稍后作者"),
            durationSeconds: 600,
            progress: progress,
            addedAt: .now,
            unavailability: unavailability
        )
    }
}

private let completedText = localized("已看完")

private func localized(_ key: String.LocalizationValue) -> String {
    String(
        localized: key,
        bundle: LibraryFeatureStrings.bundle,
        locale: Locale(identifier: "zh-Hans")
    )
}
