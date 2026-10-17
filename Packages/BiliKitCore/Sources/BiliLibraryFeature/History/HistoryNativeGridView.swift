import BiliVideoCollectionUI
import SwiftUI

/// 观看历史的已加载网格：把历史卡片呈现映射为原生卡片，交给共享的 `NativeVideoGridView`；用 AppKit 网格的
/// 理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 只负责映射与接线：分页与选择意图回送 `WatchHistoryContentView` 给出的回调，滚动位置、回顶请求与取图
/// port 来自 App 窗口的 `NativeVideoGridHostContext`。
struct HistoryNativeGridView: View {
    @Environment(\.locale) private var locale
    let content: LoadedHistoryContent
    let host: NativeVideoGridHostContext

    var body: some View {
        NativeVideoGridView(
            items: content.items.map(Self.makePresentation),
            accessibilityLabel: LibraryFeatureStrings.localized("观看历史视频", locale: locale),
            tailState: content.tailState,
            host: host,
            onNearEnd: content.loadMore,
            onSelect: content.select
        )
    }

    static func makePresentation(
        _ presentation: WatchHistoryCardPresentation
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: presentation.bvid,
            title: presentation.title,
            coverURL: presentation.coverURL,
            avatarURL: presentation.avatarURL,
            showsAvatar: presentation.showsAvatar,
            coverTrailingText: presentation.progressText,
            footerLeadingText: presentation.footerLeadingText,
            footerTrailingText: presentation.footerTrailingText,
            footerTrailingSymbolName: presentation.footerTrailingSymbolName,
            accessibilityLabel: presentation.accessibilityLabel
        )
    }
}
