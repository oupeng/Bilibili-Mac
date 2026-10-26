import Foundation

/// 视频卡片菜单项的标题，菜单与读屏「操作」转子共用同一份；各来源不另存译文。
///
/// 菜单的构造在 BiliVideoCollectionUI 的 `NativeVideoCardMenu`，这里只拥有文案。
package enum VideoCardMenuText {
    package static var copyLink: String { BiliUIStrings.localized("拷贝链接") }
    package static var openInBrowser: String { BiliUIStrings.localized("在浏览器中打开") }
    package static var addToWatchLater: String { BiliUIStrings.localized("添加到稍后再看") }
    package static var removeFromWatchLater: String { BiliUIStrings.localized("从稍后再看移除") }
    package static var addToFavorites: String { BiliUIStrings.localized("收藏到…") }
    package static var removeFromFavoriteFolder: String { BiliUIStrings.localized("从此收藏夹移除") }
}
