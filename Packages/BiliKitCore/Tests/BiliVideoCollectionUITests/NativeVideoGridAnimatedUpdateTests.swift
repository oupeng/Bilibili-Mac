import AppKit
import Testing

@testable import BiliVideoCollectionUI

/// 差异动画进行中视野跳到没有卡片的区域（回顶、一次滚出一屏、宽度变化后按锚点恢复、整体替换后回顶）时，视野里的
/// 卡片立即齐全，不等动画结束；删掉视野首卡时由后继按同一距离接替，视野不跳；尾部追加不做动画。
///
/// 运行机器开了「减少动态效果」时网格不做动画，这些用例无从验证，跳过；规则本身由 `NativeVideoGridTests` 固定。
@Suite(
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled("需要差异动画：运行机器开了「减少动态效果」") {
        await MainActor.run { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
)
@MainActor
struct NativeVideoGridAnimatedUpdateTests {
    private nonisolated static let scrollerStyles: [NSScroller.Style] = [.overlay, .legacy]

    @Test(arguments: scrollerStyles, [CGFloat(0), 12_000])
    func jumpingDuringRemovalAnimationShowsEveryVisibleCard(
        scrollerStyle: NSScroller.Style,
        target: CGFloat
    ) async throws {
        let grid = try await GridHarness(scrollerStyle: scrollerStyle)
        grid.scroll(toLogicalOffset: 6_000)
        let first = try #require(grid.firstVisibleCard())
        let removed = try #require(grid.ids.firstIndex(of: first.id)) + 1

        grid.removeItems(at: [removed])
        #expect(grid.isAnimatingUpdate)
        grid.scroll(toLogicalOffset: target)

        let counts = grid.visibleCardCounts()
        #expect(counts.expected > 0)
        #expect(counts.realized == counts.expected, "\(counts) \(grid.diagnostics)")
    }

    @Test
    func resizingDuringRemovalAnimationShowsEveryCardAndReturnsToTheSameFirstCard() async throws {
        let grid = try await GridHarness(scrollerStyle: .overlay)
        grid.scroll(toLogicalOffset: 6_000)
        let first = try #require(grid.firstVisibleCard())
        let removed = try #require(grid.ids.firstIndex(of: first.id)) + 1

        grid.removeItems(at: [removed])
        #expect(grid.isAnimatingUpdate)
        #expect(grid.firstVisibleCard() == first, "\(grid.diagnostics)")
        grid.setViewport(width: 1_120)
        let counts = grid.visibleCardCounts()
        #expect(counts.realized == counts.expected, "\(counts) \(grid.diagnostics)")
        grid.setViewport(width: 800)

        #expect(grid.firstVisibleCard() == first, "\(grid.diagnostics)")
    }

    @Test
    func removingTheFirstVisibleCardHandsItsPlaceToTheSuccessor() async throws {
        let grid = try await GridHarness(scrollerStyle: .overlay)
        grid.scroll(toLogicalOffset: 6_000)
        let first = try #require(grid.firstVisibleCard())
        let index = try #require(grid.ids.firstIndex(of: first.id))
        let successor = grid.ids[index + 1]

        grid.removeItems(at: [index])

        #expect(grid.isAnimatingUpdate)
        #expect(
            grid.firstVisibleCard()
                == .init(id: successor, offsetFromViewportTop: first.offsetFromViewportTop),
            "\(grid.diagnostics)"
        )
        let counts = grid.visibleCardCounts()
        #expect(counts.realized == counts.expected, "\(counts) \(grid.diagnostics)")
    }

    @Test
    func consecutiveRemovalsOfTheFirstVisibleCardKeepTheViewport() async throws {
        let grid = try await GridHarness(scrollerStyle: .overlay)
        grid.scroll(toLogicalOffset: 6_000)
        let first = try #require(grid.firstVisibleCard())
        let index = try #require(grid.ids.firstIndex(of: first.id))
        let secondSuccessor = grid.ids[index + 2]

        grid.removeItems(at: [index])
        #expect(grid.isAnimatingUpdate)
        // 第二次移除在第一次的动画结束前到来。
        grid.removeItems(at: [index])

        #expect(grid.isAnimatingUpdate)
        #expect(
            grid.firstVisibleCard()
                == .init(id: secondSuccessor, offsetFromViewportTop: first.offsetFromViewportTop),
            "\(grid.diagnostics)"
        )
    }

    @Test
    func replacementWithoutTheAnchorCardReturnsToTopWithEveryCardShown() async throws {
        let grid = try await GridHarness(scrollerStyle: .overlay)
        grid.scroll(toLogicalOffset: 6_000)

        grid.replaceItems(with: (0..<300).map { "NEW\($0)" })

        #expect(grid.isAnimatingUpdate)
        #expect(grid.logicalOffset == 0, "\(grid.diagnostics)")
        #expect(grid.firstVisibleCard()?.id == "NEW0", "\(grid.diagnostics)")
        let counts = grid.visibleCardCounts()
        #expect(counts.expected > 0)
        #expect(counts.realized == counts.expected, "\(counts) \(grid.diagnostics)")
    }

    @Test
    func strictTailAppendDoesNotAnimate() async throws {
        let grid = try await GridHarness(scrollerStyle: .overlay)
        grid.scroll(toLogicalOffset: 6_000)
        let first = try #require(grid.firstVisibleCard())

        grid.replaceItems(with: grid.ids + (300..<330).map { "BV\($0)" })

        #expect(!grid.isAnimatingUpdate)
        #expect(grid.firstVisibleCard() == first, "\(grid.diagnostics)")
    }
}
