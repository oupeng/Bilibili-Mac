import BiliModels
import BiliVideoCollectionUI
import SwiftUI

/// 首页推荐、热门与搜索网格的卡片菜单：三个来源的网格包装都把它交给 `NativeVideoGridView` 的 `cardMenu`。
///
/// 只有「拷贝链接」「在浏览器中打开」（`NativeVideoCardMenu.Item.videoLinks`）；卡片 ID 就是 BVID，不合法时没有菜单。
/// `openURL` 是网格包装从环境取得的系统 `OpenURLAction`。无状态。
enum BrowseVideoCardMenu {
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
