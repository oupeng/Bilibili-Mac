import BiliModels
import BiliUI
import BiliVideoCollectionUI
import Foundation
import SwiftUI
import Testing

@testable import BiliVideoDetailFeature

/// 相关推荐横排的卡片有「拷贝链接」「在浏览器中打开」，打开的是该视频的网页地址；ID 不是合法 BVID 时没有菜单。
struct RelatedVideoCardMenuTests {
    @Test @MainActor
    func relatedCardOffersTheVideoLinks() throws {
        let card = try #require(
            RelatedNativeShelfView.makePresentations([Self.related("BV1Related")]).first
        )
        var opened: [URL] = []
        let menu = try #require(
            RelatedNativeShelfView.cardMenu(
                for: card,
                openURL: OpenURLAction { url in
                    opened.append(url)
                    return .handled
                }
            )
        )

        #expect(
            menu.items.map(\.title) == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
        )
        menu.items[1].action()
        #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/BV1Related"])
    }

    @Test @MainActor
    func relatedCardWithoutAValidBVIDHasNoMenu() throws {
        let card = try #require(
            RelatedNativeShelfView.makePresentations([Self.related("BV1 spaced")]).first
        )

        #expect(
            RelatedNativeShelfView.cardMenu(for: card, openURL: OpenURLAction { _ in .handled })
                == nil
        )
    }

    private static func related(_ bvid: String) -> RelatedVideoCardPresentation {
        RelatedVideoCardPresentation(
            video: RelatedVideo(
                bvid: bvid,
                title: "相关推荐",
                coverURL: nil,
                ownerName: "作者",
                viewCount: 1,
                danmakuCount: 0,
                durationSeconds: 60
            )
        )
    }
}
