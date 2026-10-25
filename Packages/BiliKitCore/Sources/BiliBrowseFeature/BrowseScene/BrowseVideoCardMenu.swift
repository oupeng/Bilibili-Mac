import BiliModels
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 首页推荐、热门与搜索网格的卡片菜单：三个来源的网格包装都把它交给 `NativeVideoGridView` 的 `cardMenu`。
///
/// 「添加到稍后再看」一组（`writing` 为 App 从环境注入的写入口，未登录或复核中时禁用）加「拷贝链接」「在浏览器中打开」
/// 一组，规则在共用的 `NativeVideoCardMenu.video`；卡片 ID 就是 BVID，不合法时没有菜单。`openURL` 是网格包装从环境
/// 取得的系统 `OpenURLAction`。无状态。
enum BrowseVideoCardMenu {
    @MainActor
    static func menu(
        for card: NativeVideoCardPresentation,
        openURL: OpenURLAction,
        writing: VideoCardAccountWriting?
    ) -> NativeVideoCardMenu? {
        NativeVideoCardMenu.video(
            for: card,
            webPageURL: BVID.webPageURL(card.id),
            openURL: openURL,
            writing: writing,
            watchLater: .add
        )
    }
}
