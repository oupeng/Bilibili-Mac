import BiliApplication
import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 首页推荐的已加载网格：把推荐条目映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的理由见
/// ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `RecommendedFeedView` 给出的回调，卡片菜单取 `BrowseVideoCardMenu`，
/// 滚动位置、回顶请求与取图 port 来自 App 窗口的 `NativeVideoGridHostContext`。标为「不感兴趣」的条目
/// （`BrowseViewModel.dislikedRecommendations`）留在原位、显示为不可用卡片，菜单里可以撤销。
struct RecommendedNativeGridView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let content: LoadedFeedContent<RecommendedVideo>
    let disliked: [String: RecommendationFeedback]
    let host: NativeVideoGridHostContext

    var body: some View {
        let videos = Dictionary(
            content.items.map { ($0.bvid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        NativeVideoGridView(
            items: Self.makePresentations(content.items, disliked: disliked),
            accessibilityLabel: BrowseFeatureStrings.localized("首页推荐视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select,
            cardMenu: { card in
                BrowseVideoCardMenu.menu(
                    for: card,
                    openURL: openURL,
                    writing: accountWriting,
                    recommendation: disliked[card.id].map { .disliked($0) }
                        ?? videos[card.id].map { .notDisliked($0) }
                )
            }
        )
    }

    /// 标为「不感兴趣」的卡片不可进入播放，封面角标与读屏标签开头说明「将减少此类推荐」。
    static func makePresentations(
        _ videos: [RecommendedVideo],
        disliked: [String: RecommendationFeedback],
        locale: Locale = InterfaceLocale.current
    ) -> [NativeVideoCardPresentation] {
        // 条目已由 `PagedVideoList` 按 BVID 去重，卡片 ID 因此唯一。
        videos.map { video in
            let presentation = RecommendedVideoCardPresentation(video: video, locale: locale)
            let dislikedBadge = disliked[video.bvid] == nil ? nil : VideoCardMenuText.dislikedBadge
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
                accessibilityLabel: dislikedBadge.map {
                    ListFormatter.localizedString(byJoining: [$0, presentation.accessibilityLabel])
                } ?? presentation.accessibilityLabel,
                availability: dislikedBadge.map { .unavailable(badge: $0) } ?? .available
            )
        }
    }
}
