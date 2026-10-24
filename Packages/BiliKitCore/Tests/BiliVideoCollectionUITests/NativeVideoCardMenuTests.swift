import AppKit
import BiliUI
import SwiftUI
import Testing

@testable import BiliVideoCollectionUI

/// 卡片菜单：右键菜单与读屏自定义操作出自同一份描述，项、顺序与标题一致；「拷贝链接」「在浏览器中打开」只给可进入
/// 播放且有网页地址的卡片，打开交给系统 `OpenURLAction` 的正是该卡片的地址；没有项时不弹菜单；Control-点按走右键
/// 同一条菜单路径，不激活卡片。
struct NativeVideoCardMenuTests {
    @Test @MainActor
    func playableCardWithAWebPageOffersCopyThenOpenInBrowser() throws {
        let webPage = try #require(URL(string: "https://www.bilibili.com/video/BV1Menu"))
        var opened: [URL] = []
        let items = NativeVideoCardMenu.Item.videoLinks(
            for: Self.card(id: "BV1Menu", availability: .available),
            webPageURL: webPage,
            openURL: OpenURLAction { url in
                opened.append(url)
                return .handled
            }
        )

        #expect(items.map(\.title) == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser])
        #expect(items.map(\.systemImage) == ["link", "globe"])
        items[1].action()
        #expect(opened == [webPage])
    }

    @Test @MainActor
    func unavailableCardsAndCardsWithoutAWebPageHaveNoMenu() throws {
        let webPage = try #require(URL(string: "https://www.bilibili.com/video/BV1Gone"))
        let openURL = OpenURLAction { _ in .handled }
        let unavailable = NativeVideoCardMenu.Item.videoLinks(
            for: Self.card(id: "BV1Gone", availability: .unavailable(badge: "已失效")),
            webPageURL: webPage,
            openURL: openURL
        )
        let withoutWebPage = NativeVideoCardMenu.Item.videoLinks(
            for: Self.card(id: "fav-21-1", availability: .available),
            webPageURL: nil,
            openURL: openURL
        )

        #expect(unavailable.isEmpty)
        #expect(withoutWebPage.isEmpty)
        #expect(NativeVideoCardMenu(items: unavailable) == nil)
    }

    @Test @MainActor
    func menuAndAccessibilityActionsShareItemsTitlesAndOrder() throws {
        var performed: [String] = []
        let titles = ["第一项", "第二项", "第三项"]
        let menu = try #require(
            NativeVideoCardMenu(
                items: titles.map { title in
                    NativeVideoCardMenu.Item(title: title, systemImage: "star") {
                        performed.append(title)
                    }
                }
            )
        )

        let nsMenu = menu.makeMenu()
        let actions = menu.accessibilityCustomActions
        #expect(nsMenu.items.map(\.title) == titles)
        #expect(actions.map(\.name) == titles)

        for menuItem in nsMenu.items {
            let target = try #require(menuItem.target as? NSObject)
            _ = target.perform(menuItem.action, with: menuItem)
        }
        for action in actions {
            #expect(action.handler?() == true)
        }
        #expect(performed == titles + titles)
    }

    /// 网格卡片的读屏操作取自注入的 `cardMenu`：传入的是这张卡片的呈现，网格拆除后卡片不再有操作。
    @Test(.timeLimit(.minutes(1))) @MainActor
    func gridCardsExposeTheInjectedMenuAsAccessibilityActions() async throws {
        var opened: [URL] = []
        let openURL = OpenURLAction { url in
            opened.append(url)
            return .handled
        }
        let coordinator = NativeVideoGridView.Coordinator(
            items: [
                Self.card(id: "BV1Menu0", availability: .available),
                Self.card(id: "BV1Menu1", availability: .unavailable(badge: "已失效"))
            ],
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: .end,
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: NativeVideoGridActions(
                onNearEnd: {},
                onSelect: { _ in },
                cardMenu: { card in
                    NativeVideoCardMenu(
                        items: NativeVideoCardMenu.Item.videoLinks(
                            for: card,
                            webPageURL: URL(string: "https://www.bilibili.com/video/\(card.id)"),
                            openURL: openURL
                        )
                    )
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = coordinator.makeScrollView()
        window.contentView = scrollView
        defer { window.contentView = NSView() }
        // makeScrollView 把首次排版排到下一轮主队列；等它跑完再取卡片。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        scrollView.layoutSubtreeIfNeeded()
        let collectionView = try #require(scrollView.documentView as? NSCollectionView)
        let cards = Dictionary(
            uniqueKeysWithValues: collectionView.visibleItems()
                .compactMap { $0 as? NativeVideoCollectionItem }
                .compactMap { item in item.representedVideoID.map { ($0, item.view) } }
        )
        let available = try #require(cards["BV1Menu0"])
        let unavailable = try #require(cards["BV1Menu1"])

        let actions = try #require(available.accessibilityCustomActions())
        #expect(
            actions.map(\.name) == [VideoCardMenuText.copyLink, VideoCardMenuText.openInBrowser]
        )
        #expect(actions[1].handler?() == true)
        #expect(opened.map(\.absoluteString) == ["https://www.bilibili.com/video/BV1Menu0"])
        #expect(unavailable.accessibilityCustomActions()?.isEmpty ?? true)

        coordinator.reset()
        #expect(available.accessibilityCustomActions()?.isEmpty ?? true)
    }

    /// 打开卡片菜单的两个非右键入口。
    enum MenuEntry: String, CaseIterable {
        /// Control-点按沿响应链到达网格的 `mouseDown`。
        case controlClick
        /// 读屏「显示菜单」。
        case accessibilityShowMenu
    }

    /// Control-点按与读屏「显示菜单」都走右键同一条菜单路径。
    ///
    /// 取这张卡片的菜单并弹出，打开期间画上下文描边，不当作点击激活。用例观察的是进程内所有菜单的跟踪通知，并行会互相关掉对方的菜单，所以串行。
    @Test(.serialized, .timeLimit(.minutes(1)), arguments: MenuEntry.allCases) @MainActor
    func entriesOpenTheCardMenuThroughTheRightClickPath(entry: MenuEntry) async throws {
        var requestedIDs: [String] = []
        var selections: [String] = []
        let coordinator = NativeVideoGridView.Coordinator(
            items: [Self.card(id: "BV1Menu0", availability: .available)],
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: .end,
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            actions: NativeVideoGridActions(
                onNearEnd: {},
                onSelect: { selections.append($0) },
                cardMenu: { card in
                    requestedIDs.append(card.id)
                    return NativeVideoCardMenu(
                        items: [NativeVideoCardMenu.Item(title: "菜单项", systemImage: "link") {}]
                    )
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = coordinator.makeScrollView()
        window.contentView = scrollView
        defer {
            coordinator.reset()
            window.contentView = NSView()
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        scrollView.layoutSubtreeIfNeeded()
        let collectionView = try #require(scrollView.documentView as? NSCollectionView)
        let card = try #require(collectionView.visibleItems().first?.view)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil),
                modifierFlags: .control,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        // 菜单进入跟踪循环后，在循环里记下卡片的描边再关闭菜单。
        var borderWidthWhileOpen: CGFloat?
        let observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: nil
        ) { notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu
            RunLoop.current.perform(inModes: [.eventTracking, .default]) {
                MainActor.assumeIsolated {
                    borderWidthWhileOpen = card.layer?.borderWidth
                    menu?.cancelTrackingWithoutAnimation()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        switch entry {
        case .controlClick:
            collectionView.mouseDown(with: event)
        case .accessibilityShowMenu:
            #expect(card.accessibilityPerformShowMenu())
            // 读屏入口推到下一轮主队列才弹出；等菜单开始跟踪，超时由 time limit 兜底。
            while borderWidthWhileOpen == nil {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }

        #expect(Set(requestedIDs) == ["BV1Menu0"])
        #expect((borderWidthWhileOpen ?? 0) > 0)
        #expect(card.layer?.borderWidth == 0)
        #expect(selections.isEmpty)
        #expect(collectionView.selectionIndexPaths.isEmpty)
    }

    private static func card(
        id: String,
        availability: NativeVideoCardAvailability
    ) -> NativeVideoCardPresentation {
        NativeVideoCardPresentation(
            id: id,
            title: "手写卡片",
            coverURL: nil,
            avatarURL: nil,
            showsAvatar: false,
            footerLeadingText: "作者",
            accessibilityLabel: "手写卡片",
            availability: availability
        )
    }
}
