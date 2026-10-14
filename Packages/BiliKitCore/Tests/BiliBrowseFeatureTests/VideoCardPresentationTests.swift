import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

struct VideoCardPresentationTests {
    private let locale = Locale(
        identifier: BrowseFeatureStrings.bundle.preferredLocalizations.first ?? "en"
    )
    private let owner = VideoOwner(id: 1, name: "示例 UP 主")
    private let statistics = VideoStatistics(viewCount: 123_456, danmakuCount: 789, likeCount: 3)
    private let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func popularLabelReadsEveryVisibleSlotIncludingPublishedDate() {
        let presentation = PopularVideoCardPresentation(
            video: PopularVideo(
                bvid: "BV1Popular",
                title: "热门示例",
                coverURL: nil,
                owner: owner,
                statistics: statistics,
                durationSeconds: 754,
                publishedAt: publishedAt
            ),
            locale: locale
        )

        for value in visibleValues(
            title: presentation.title,
            viewCountText: presentation.viewCountText,
            danmakuCountText: presentation.danmakuCountText,
            durationText: presentation.durationText
        ) {
            #expect(presentation.accessibilityLabel.contains(value))
        }
    }

    @Test
    func recommendedLabelAddsReasonOnlyWhenPresent() {
        let withReason = RecommendedVideoCardPresentation(
            video: recommendedVideo(reason: "正在流行"),
            locale: locale
        )
        let withoutReason = RecommendedVideoCardPresentation(
            video: recommendedVideo(reason: nil),
            locale: locale
        )

        for value in visibleValues(
            title: withReason.title,
            viewCountText: withReason.viewCountText,
            danmakuCountText: withReason.danmakuCountText,
            durationText: withReason.durationText
        ) {
            #expect(withReason.accessibilityLabel.contains(value))
            #expect(withoutReason.accessibilityLabel.contains(value))
        }
        #expect(withReason.accessibilityLabel.contains("正在流行"))
        #expect(!withoutReason.accessibilityLabel.contains("正在流行"))
    }

    private func recommendedVideo(reason: String?) -> RecommendedVideo {
        RecommendedVideo(
            bvid: "BV1Recommended",
            title: "推荐示例",
            coverURL: nil,
            owner: owner,
            statistics: statistics,
            durationSeconds: 754,
            publishedAt: publishedAt,
            recommendationReason: reason
        )
    }

    /// 卡片上可见的全部文字：标题、UP 主、播放、弹幕、时长与发布日期。
    private func visibleValues(
        title: String,
        viewCountText: String,
        danmakuCountText: String,
        durationText: String
    ) -> [String] {
        [
            title,
            owner.name,
            viewCountText,
            danmakuCountText,
            durationText,
            VideoMetadataFormatting.publishedDate(publishedAt, locale: locale)
        ]
    }
}
