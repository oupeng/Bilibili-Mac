import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliLibraryFeature

/// 观看历史与收藏夹里可以播放的卡片有「添加到稍后再看」，稍后再看页的卡片有「从稍后再看移除」（带 ⌘⌫），两者之后是
/// 「拷贝链接」「在浏览器中打开」；稍后再看里失效的视频只能移除，其他来源的不可用卡片与 ID 不是 BVID 的收藏条目没有菜单。
struct LibraryVideoCardMenuTests {
    @Test @MainActor
    func playableCardsOfferTheirWatchLaterActionAndVideoLinks() throws {
        let cases: [(NativeVideoCardPresentation, NativeVideoCardMenu.WatchLaterAction, String)] = [
            (WatchHistoryCardPresentation(item: item("BV1History")).nativeCard, .add, VideoCardMenuText.addToWatchLater),
            (WatchLaterCardPresentation(item: laterItem("BV1Later")).nativeCard, .remove, VideoCardMenuText.removeFromWatchLater),
            (FavoriteCardPresentation(item: favoriteItem("BV1Favorite")).nativeCard, .add, VideoCardMenuText.addToWatchLater)
        ]

        for (card, action, writeTitle) in cases {
            var opened: [URL] = []
            let writes = RecordedWrites()
            let menu = try #require(
                LibraryVideoCardMenu.menu(
                    for: card,
                    openURL: OpenURLAction { url in
                        opened.append(url)
                        return .handled
                    },
                    writing: writes.writing,
                    watchLater: action
                )
            )
            #expect(
                menu.items.map(\.title)
                    == [writeTitle, VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
            )
            menu.items[0].action()
            menu.items[2].action()
            #expect(writes.events == ["\(action == .add ? "add" : "remove") \(card.id)"])
            #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/\(card.id)"])
        }
    }

    /// 稍后再看里失效的视频只剩「从稍后再看移除」，⌘⌫ 执行的就是它。
    @Test @MainActor
    func unavailableWatchLaterItemsCanOnlyBeRemoved() throws {
        let card = WatchLaterCardPresentation(
            item: laterItem("BV1LaterGone", unavailability: .invalid)
        ).nativeCard
        let writes = RecordedWrites()

        let menu = try #require(
            LibraryVideoCardMenu.menu(
                for: card,
                openURL: OpenURLAction { _ in .handled },
                writing: writes.writing,
                watchLater: .remove
            )
        )

        #expect(menu.items.map(\.title) == [VideoCardMenuText.removeFromWatchLater])
        menu.enabledItem(for: .commandDelete)?.action()
        #expect(writes.events == ["remove BV1LaterGone"])
    }

    @Test @MainActor
    func otherUnavailableCardsAndCardsWithoutABVIDHaveNoMenu() {
        let favoriteGone = favoriteItem("BV1FavoriteGone", unavailability: .invalid)
        let collection = favoriteItem("fav-21-1", unavailability: .collection)
        let cards = [
            FavoriteCardPresentation(item: favoriteGone).nativeCard,
            FavoriteCardPresentation(item: collection).nativeCard
        ]
        let openURL = OpenURLAction { _ in .handled }
        let writes = RecordedWrites()

        for card in cards {
            #expect(
                LibraryVideoCardMenu.menu(
                    for: card,
                    openURL: openURL,
                    writing: writes.writing,
                    watchLater: .add
                ) == nil
            )
        }
    }
}

/// 记录写入口收到的意图；闭包在主线程调用。
@MainActor
private final class RecordedWrites {
    var events: [String] = []

    var writing: VideoCardAccountWriting {
        VideoCardAccountWriting(
            isAvailable: { true },
            addToWatchLater: { [weak self] in self?.events.append("add \($0)") },
            removeFromWatchLater: { [weak self] in self?.events.append("remove \($0)") }
        )
    }
}
