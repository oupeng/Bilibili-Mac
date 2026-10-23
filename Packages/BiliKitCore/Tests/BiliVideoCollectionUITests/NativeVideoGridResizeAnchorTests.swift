import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

/// 视口宽度变化（含侧栏收起、展开动画中的连续变化）前后，网格的首张可见卡片不变。
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativeVideoGridResizeAnchorTests {
    /// 侧栏收起、展开时细节栏的宽度：每步约一帧，跨过 2、3、4 列。
    private static let sidebarAnimationWidths: [CGFloat] = Array(
        stride(from: 800, through: 1_120, by: 20)
    )

    @Test
    func continuousWidenThenNarrowKeepsTheFirstVisibleCard() async throws {
        let grid = try await GridHarness()
        grid.scroll(toLogicalOffset: 6_000)
        let original = try #require(grid.firstVisibleCard())

        for width in Self.sidebarAnimationWidths.dropFirst()
            + Self.sidebarAnimationWidths.reversed().dropFirst()
        {
            grid.setViewportWidth(width)
            let card = try #require(grid.card(original.id))
            #expect(
                abs(card.offsetFromViewportTop - original.offsetFromViewportTop) <= 1,
                "宽度 \(width) 时首卡 \(original.id) 离开了视野顶部"
            )
        }
        #expect(grid.firstVisibleCard() == original)
    }

    @Test
    func narrowingNearTheEndReturnsToTheSameFirstVisibleCard() async throws {
        let grid = try await GridHarness(initialWidth: 1_120)
        grid.scroll(toLogicalOffset: grid.maximumLogicalOffset - 120)
        let original = try #require(grid.firstVisibleCard())

        for width in Self.sidebarAnimationWidths.reversed().dropFirst()
            + Self.sidebarAnimationWidths.dropFirst()
        {
            grid.setViewportWidth(width)
        }
        #expect(grid.firstVisibleCard() == original)
    }
}

/// 带工具栏（顶部 contentInsets）的真实窗口里驱动网格 Coordinator，宽度变化经窗口布局同步送达。
@MainActor
private final class GridHarness {
    struct VisibleCard: Equatable {
        let id: String
        let offsetFromViewportTop: CGFloat
    }

    private static let itemCount = 300
    private static let viewportHeight: CGFloat = 700

    private let coordinator: NativeVideoGridView.Coordinator
    private let window: NSWindow
    private let scrollView: NSScrollView
    private let collectionView: NSCollectionView

    init(initialWidth: CGFloat = 800) async throws {
        coordinator = NativeVideoGridView.Coordinator(
            items: (0..<Self.itemCount).map { index in
                NativeVideoCardPresentation(
                    id: "BV\(index)",
                    title: "视频 \(index)",
                    coverURL: nil,
                    avatarURL: nil,
                    showsAvatar: false,
                    footerLeadingText: "UP",
                    accessibilityLabel: "视频 \(index)"
                )
            },
            initialScrollOffsetY: 0,
            accessibilityLabel: "网格",
            tailState: .end,
            bottomInset: 0,
            scrollResetRequestID: 0,
            acknowledgedScrollResetRequestID: 0,
            imagePipeline: StubCardImageLoader(),
            onScroll: { _ in },
            onAcknowledgeScrollReset: { _ in },
            onNearEnd: {},
            onSelect: { _ in }
        )
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: Self.viewportHeight),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "GridHarness")
        scrollView = coordinator.makeScrollView()
        let contentView = try #require(window.contentView)
        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)
        collectionView = try #require(scrollView.documentView as? NSCollectionView)
        contentView.layoutSubtreeIfNeeded()
        // makeScrollView 把首次排版与恢复排到下一轮主队列；等它跑完再开始操作。
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    isolated deinit {
        coordinator.reset()
        window.contentView = nil
    }

    var maximumLogicalOffset: CGFloat {
        NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
            documentLength: collectionView.frame.height,
            viewportLength: scrollView.contentSize.height,
            leadingInset: scrollView.contentInsets.top,
            trailingInset: scrollView.contentInsets.bottom
        )
    }

    /// 像用户滚动一样直接移动 clip view，网格经 bounds 通知记录；随后的布局让集合视图为新视野准备卡片。
    func scroll(toLogicalOffset offsetY: CGFloat) {
        scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: offsetY,
                leadingInset: scrollView.contentInsets.top
            )
        )
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func setViewportWidth(_ width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: Self.viewportHeight))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// 与视野相交的最上一行里最靠前的卡片。
    func firstVisibleCard() -> VisibleCard? {
        let visible = collectionView.visibleRect
        return (0..<collectionView.numberOfItems(inSection: 0))
            .compactMap { item -> (Int, NSRect)? in
                guard
                    let frame = collectionView.collectionViewLayout?
                        .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame,
                    frame.intersects(visible)
                else { return nil }
                return (item, frame)
            }
            .min { ($0.1.minY, $0.0) < ($1.1.minY, $1.0) }
            .flatMap { card("BV\($0.0)") }
    }

    /// 卡片顶边到视口逻辑顶边（工具栏下沿）的距离。
    func card(_ id: String) -> VisibleCard? {
        guard
            let item = Int(id.dropFirst(2)),
            let frame = collectionView.collectionViewLayout?
                .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame
        else { return nil }
        let logicalTop = NativeVideoScrollCoordinateSpace.logicalOffset(
            physicalOffset: scrollView.contentView.bounds.origin.y,
            leadingInset: scrollView.contentInsets.top
        )
        return VisibleCard(id: id, offsetFromViewportTop: frame.minY - logicalTop)
    }
}
