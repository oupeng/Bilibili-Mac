import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliLibraryFeature

/// 观看历史、稍后再看与收藏夹里可以播放的卡片都有「拷贝链接」「在浏览器中打开」，打开的是该视频的网页地址；
/// 不可用卡片（即使带合法 BVID）与 ID 不是 BVID 的收藏条目没有菜单。
struct LibraryVideoCardMenuTests {
    @Test @MainActor
    func playableCardsOfEveryLibrarySourceOfferTheVideoLinks() throws {
        let cards = [
            WatchHistoryCardPresentation(item: item("BV1History")).nativeCard,
            WatchLaterCardPresentation(item: laterItem("BV1Later")).nativeCard,
            FavoriteCardPresentation(item: favoriteItem("BV1Favorite")).nativeCard
        ]

        for card in cards {
            var opened: [URL] = []
            let menu = try #require(
                LibraryVideoCardMenu.menu(
                    for: card,
                    openURL: OpenURLAction { url in
                        opened.append(url)
                        return .handled
                    }
                )
            )
            #expect(
                menu.items.map(\.title)
                    == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
            )
            menu.items[1].action()
            #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/\(card.id)"])
        }
    }

    @Test @MainActor
    func unavailableCardsAndCardsWithoutABVIDHaveNoMenu() {
        let laterGone = laterItem("BV1LaterGone", unavailability: .invalid)
        let favoriteGone = favoriteItem("BV1FavoriteGone", unavailability: .invalid)
        let collection = favoriteItem("fav-21-1", unavailability: .collection)
        let cards = [
            WatchLaterCardPresentation(item: laterGone).nativeCard,
            FavoriteCardPresentation(item: favoriteGone).nativeCard,
            FavoriteCardPresentation(item: collection).nativeCard
        ]
        let openURL = OpenURLAction { _ in .handled }

        for card in cards {
            #expect(LibraryVideoCardMenu.menu(for: card, openURL: openURL) == nil)
        }
    }
}
