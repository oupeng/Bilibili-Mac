import BiliModels
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 首页推荐的已加载网格：把推荐条目映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的理由见
/// ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `RecommendedFeedView` 给出的回调，卡片菜单取 `BrowseVideoCardMenu`，
/// 滚动位置、回顶请求与取图 port 来自 App 窗口的 `NativeVideoGridHostContext`。
struct RecommendedNativeGridView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    let content: LoadedFeedContent<RecommendedVideo>
    let host: NativeVideoGridHostContext

    var body: some View {
        NativeVideoGridView(
            items: Self.makePresentations(content.items, locale: locale),
            accessibilityLabel: BrowseFeatureStrings.localized("首页推荐视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select,
            cardMenu: { BrowseVideoCardMenu.menu(for: $0, openURL: openURL) }
        )
    }

    static func makePresentations(
        _ videos: [RecommendedVideo],
        locale: Locale = .current
    ) -> [NativeVideoCardPresentation] {
        // 条目已由 `PagedVideoList` 按 BVID 去重，卡片 ID 因此唯一。
        videos.map { video in
            let presentation = RecommendedVideoCardPresentation(video: video, locale: locale)
            return NativeVideoCardPresentation(
                id: presentation.bvid,
                title: presentation.title,
                coverURL: presentation.coverURL,
                avatarURL: presentation.avatarURL,
                showsAvatar: true,
                coverMetrics: [
                    NativeVideoCardMetric(
                        text: presentation.viewCountText,
                        systemImage: "play.fill"
                    ),
                    NativeVideoCardMetric(
                        text: presentation.danmakuCountText,
                        systemImage: "text.bubble.fill"
                    )
                ],
                coverTrailingText: presentation.durationText,
                footerLeadingText: presentation.footerText,
                footerTrailingText: presentation.recommendationReason,
                footerTrailingStyle: presentation.recommendationReason == nil
                    ? .plain
                    : .brandOutlinedCapsule,
                accessibilityLabel: presentation.accessibilityLabel
            )
        }
    }
}
