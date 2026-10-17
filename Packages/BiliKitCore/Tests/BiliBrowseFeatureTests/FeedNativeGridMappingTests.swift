import BiliModels
import BiliVideoCollectionUI
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 首页推荐映射到原生卡片时：同一 BVID 只出一张卡，推荐理由只在存在时显示为品牌描边胶囊，读屏标签与卡片
/// 呈现一致。
struct FeedNativeGridMappingTests {
    @Test @MainActor
    func recommendationMappingUsesBrandCapsuleOnlyWhenReasonExists() throws {
        let video = RecommendedVideo(
            bvid: "BV-rcmd-stable",
            title: "首页推荐卡片",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 125,
            publishedAt: Date(timeIntervalSince1970: 0),
            recommendationReason: "正在流行"
        )

        let content = try #require(
            RecommendedNativeGridView.makePresentations([video, video]).first
        )
        #expect(RecommendedNativeGridView.makePresentations([video, video]).count == 1)
        #expect(content.footerTrailingText == "正在流行")
        #expect(content.footerTrailingStyle == .brandOutlinedCapsule)
        #expect(
            content.accessibilityLabel
                == RecommendedVideoCardPresentation(video: video).accessibilityLabel
        )

        let withoutReason = RecommendedVideo(
            bvid: "BV-rcmd-plain",
            title: video.title,
            coverURL: nil,
            owner: video.owner,
            statistics: video.statistics,
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            recommendationReason: nil
        )
        let plain = try #require(
            RecommendedNativeGridView.makePresentations([withoutReason]).first
        )
        #expect(plain.footerTrailingText == nil)
        #expect(plain.footerTrailingStyle == .plain)
    }
}
