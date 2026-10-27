import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 搜索结果的已加载网格：把搜索卡片呈现映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的
/// 理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `VideoSearchView` 给出的回调，卡片菜单取 `BrowseVideoCardMenu`，
/// 滚动位置、回顶请求与取图 port 来自 App 窗口的 `NativeVideoGridHostContext`。
struct SearchNativeGridView: View {
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @Environment(\.videoCardAccountWriting) private var accountWriting
    let content: LoadedFeedContent<SearchVideoCardPresentation>
    let host: NativeVideoGridHostContext

    var body: some View {
        NativeVideoGridView(
            items: content.items.map(Self.makePresentation),
            accessibilityLabel: BrowseFeatureStrings.localized("搜索结果视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select,
            cardMenu: {
                BrowseVideoCardMenu.menu(for: $0, openURL: openURL, writing: accountWriting)
            }
        )
    }

    static func makePresentation(
        _ presentation: SearchVideoCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
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
