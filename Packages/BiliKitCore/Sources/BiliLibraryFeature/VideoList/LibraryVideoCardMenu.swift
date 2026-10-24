import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 观看历史、稍后再看与收藏夹网格的卡片菜单：列表主区（`LibraryVideoListContentView`）与收藏夹内容
/// （`FavoriteFolderContentView`）都把它交给 `NativeVideoGridView` 的 `cardMenu`。
///
/// 只有「拷贝链接」「在浏览器中打开」（`NativeVideoCardMenu.Item.videoLinks`）：不可用卡片（失效、合集、课程等）与
/// ID 不是合法 BVID 的卡片（收藏夹里没有 BVID 的条目）没有菜单。`openURL` 是视图从环境取得的系统 `OpenURLAction`。
/// 无状态。
enum LibraryVideoCardMenu {
    @MainActor
    static func menu(
        for card: NativeVideoCardPresentation,
        openURL: OpenURLAction
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu(
            items: NativeVideoCardMenu.Item.videoLinks(
                for: card,
                webPageURL: BVID.webPageURL(card.id),
                openURL: openURL
            )
        )
    }
}
