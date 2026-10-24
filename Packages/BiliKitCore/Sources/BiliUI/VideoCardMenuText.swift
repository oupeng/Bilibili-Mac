import Foundation

/// 视频卡片菜单项的标题，菜单与读屏「操作」转子共用同一份；各来源不另存译文。
///
/// 菜单的构造在 BiliVideoCollectionUI 的 `NativeVideoCardMenu`，这里只拥有文案。
package enum VideoCardMenuText {
    package static var copyLink: String { BiliUIStrings.localized("拷贝链接") }
    package static var openInBrowser: String { BiliUIStrings.localized("在浏览器中打开") }
}
