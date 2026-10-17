import BiliModels
import BiliVideoCollectionUI
import Foundation
import SwiftUI

/// 热门的已加载网格：把热门条目映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的理由见
/// ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `PopularFeedView` 给出的回调，滚动位置、回顶请求与取图 port
/// 来自 App 窗口的 `NativeVideoGridHostContext`。
struct PopularNativeGridView: View {
    @Environment(\.locale) private var locale
    let content: LoadedFeedContent<PopularVideo>
    let host: NativeVideoGridHostContext

    var body: some View {
        NativeVideoGridView(
            items: Self.makePresentations(content.items, locale: locale),
            accessibilityLabel: BrowseFeatureStrings.localized("热门视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select
        )
    }

    static func makePresentations(
        _ videos: [PopularVideo],
        locale: Locale = .current
    ) -> [NativeVideoCardPresentation] {
        var seenBVIDs: Set<String> = []
        return videos.compactMap { video in
            guard seenBVIDs.insert(video.bvid).inserted else { return nil }
            let presentation = PopularVideoCardPresentation(video: video, locale: locale)
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
                accessibilityLabel: presentation.accessibilityLabel
            )
        }
    }
}
