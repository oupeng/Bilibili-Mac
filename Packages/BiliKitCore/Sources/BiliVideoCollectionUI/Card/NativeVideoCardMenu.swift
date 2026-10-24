import AppKit
import BiliUI
import SwiftUI

/// 视频卡片的菜单描述：右键／Control-点按与读屏「显示菜单」弹出的 `NSMenu`，以及卡片的读屏自定义操作
/// （VoiceOver「操作」转子）都只由它生成，两处的项、顺序与标题因此一致。
///
/// 各来源的 Feature 按卡片构造（经 `NativeVideoGridView`、相关推荐横排的 `cardMenu` 注入），哪些项出现由来源决定；
/// 集合视图只在命中卡片时取用，取到 nil 就不弹菜单。描述是一次性的值：不持有卡片、集合视图或会话，每次弹出
/// 或读屏询问时重新构造。动作在主线程、菜单关闭后或读屏执行操作时调用。
@MainActor
package struct NativeVideoCardMenu {
    /// 一个菜单项：标题、SF Symbol 名与动作。
    package struct Item {
        package let title: String
        package let systemImage: String
        package let action: @MainActor () -> Void

        package init(
            title: String,
            systemImage: String,
            action: @escaping @MainActor () -> Void
        ) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }
    }

    package let items: [Item]

    /// 没有任何项时构造失败：调用方据此不弹菜单，也不给读屏空的操作列表。
    package init?(items: [Item]) {
        guard !items.isEmpty else { return nil }
        self.items = items
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for item in items {
            let target = NativeVideoCardMenuActionTarget(action: item.action)
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(NativeVideoCardMenuActionTarget.performAction(_:)),
                keyEquivalent: ""
            )
            menuItem.image = NSImage(
                systemSymbolName: item.systemImage,
                accessibilityDescription: nil
            )
            // `target` 是弱引用，由 `representedObject` 持有动作对象直到菜单项释放。
            menuItem.target = target
            menuItem.representedObject = target
            menu.addItem(menuItem)
        }
        return menu
    }

    var accessibilityCustomActions: [NSAccessibilityCustomAction] {
        items.map { item in
            let action = item.action
            return NSAccessibilityCustomAction(name: item.title) {
                // 读屏在主线程执行自定义操作。
                MainActor.assumeIsolated { action() }
                return true
            }
        }
    }
}

extension NativeVideoCardMenu.Item {
    /// 「拷贝链接」「在浏览器中打开」两项：只给可进入播放、且调用方给出网页地址的卡片，否则为空。
    ///
    /// `webPageURL` 由 Feature 用 BiliModels 的 `BVID.webPageURL` 按卡片 ID 构造，BVID 不合法时为 nil。拷贝把同一地址
    /// 同时写成 URL 与纯文本；打开只经系统的 `OpenURLAction`，不预取、不附加凭据，见 SECURITY-MODEL §4。
    package static func videoLinks(
        for card: NativeVideoCardPresentation,
        webPageURL: URL?,
        openURL: OpenURLAction
    ) -> [Self] {
        guard card.isActivatable, let webPageURL else { return [] }
        return [
            Self(title: VideoCardMenuText.copyLink, systemImage: "link") {
                let item = NSPasteboardItem()
                item.setString(webPageURL.absoluteString, forType: .URL)
                item.setString(webPageURL.absoluteString, forType: .string)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item])
            },
            Self(title: VideoCardMenuText.openInBrowser, systemImage: "globe") {
                openURL(webPageURL)
            }
        ]
    }
}

/// `NSMenuItem` 的 target-action 接收者：只持有一个菜单项的动作，随菜单项释放。
@MainActor
private final class NativeVideoCardMenuActionTarget: NSObject {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    @objc func performAction(_ sender: Any?) {
        action()
    }
}

extension NativeVideoCardCollectionView {
    /// 卡片菜单的唯一取用处：右键、读屏自定义操作与读屏「显示菜单」都经这里，只把卡片 ID 交给 `cardMenu`。
    func cardMenu(for item: NativeVideoCollectionItem) -> NativeVideoCardMenu? {
        guard let id = item.representedVideoID else { return nil }
        return cardMenu?(id)
    }

    /// 读屏「显示菜单」：在卡片旁弹出与右键相同的菜单，期间画上下文描边。
    ///
    /// 推到下一轮 runloop 再弹：菜单的跟踪循环会一直阻塞到菜单关闭，在辅助功能请求里同步弹出会让读屏等到超时。
    /// 届时卡片可能已被复用给其他视频，所以按发起时的 ID 重新核对。
    func presentCardMenu(for item: NativeVideoCollectionItem) -> Bool {
        guard let id = item.representedVideoID, cardMenu(for: item) != nil else { return false }
        DispatchQueue.main.async { [weak self, weak item] in
            guard
                let self,
                let item,
                item.representedVideoID == id,
                let menu = self.cardMenu(for: item)
            else { return }
            let view = item.view
            item.setContextMenuTarget(true)
            menu.makeMenu().popUp(
                positioning: nil,
                at: NSPoint(x: view.bounds.minX, y: view.bounds.midY),
                in: view
            )
            item.setContextMenuTarget(false)
        }
        return true
    }
}

extension NativeVideoCollectionItem {
    /// 卡片读屏入口（`NativeVideoCardView`）取菜单与弹出菜单都转给所在的集合视图；不在集合视图里时没有菜单。
    var cardMenu: NativeVideoCardMenu? {
        (collectionView as? NativeVideoCardCollectionView)?.cardMenu(for: self)
    }

    func presentCardMenu() -> Bool {
        (collectionView as? NativeVideoCardCollectionView)?.presentCardMenu(for: self) ?? false
    }
}
