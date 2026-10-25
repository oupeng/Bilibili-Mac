import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 观看历史、稍后再看与收藏夹网格的卡片菜单：列表主区（`LibraryVideoListContentView`）与收藏夹内容
/// （`FavoriteFolderContentView`）都把它交给 `NativeVideoGridView` 的 `cardMenu`。
///
/// 稍后再看写操作一组加「拷贝链接」「在浏览器中打开」一组，规则在共用的 `NativeVideoCardMenu.video`：观看历史与收藏夹给
/// 「添加到稍后再看」（只给可进入播放的卡片），稍后再看页给「从稍后再看移除」（⌘⌫ 同一项；失效等不可用条目也能移除，
/// 但没有链接项）。ID 不是合法 BVID 的卡片（收藏夹里没有 BVID 的条目）没有菜单。`writing` 是 App 从环境注入的写入口，
/// 未登录或复核中时写操作项禁用；`openURL` 是视图从环境取得的系统 `OpenURLAction`。无状态。
enum LibraryVideoCardMenu {
    @MainActor
    static func menu(
        for card: NativeVideoCardPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?,
        watchLater: NativeVideoCardMenu.WatchLaterAction
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            for: card,
            webPageURL: BVID.webPageURL(card.id),
            openURL: openURL,
            writing: writing,
            watchLater: watchLater
        )
    }
}
