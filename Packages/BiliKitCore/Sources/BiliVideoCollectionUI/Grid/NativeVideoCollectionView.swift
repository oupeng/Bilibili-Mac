import AppKit
import BiliUI

/// 网格的集合视图：扩大预备区域，并处理点击激活与按列数移动的键盘选择。
///
/// 只由 `NativeVideoGridView` 创建；用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
@MainActor
final class NativeVideoCollectionView: NativeVideoCardCollectionView {
    /// AppKit 默认只准备视野内的卡片，封面要等卡片露出来才开始加载；这里上下各多准备一屏。
    ///
    /// 因此 `indexPathsForVisibleItems()` 也包含视野外已准备的卡片；需要视野首卡时用 `firstVisibleItem()`。
    override func prepareContent(in rect: NSRect) {
        guard !visibleRect.isEmpty else {
            super.prepareContent(in: rect)
            return
        }
        super.prepareContent(
            in: NativeVideoGridGeometry.preparedContentRect(visible: visibleRect, bounds: bounds)
        )
    }

    /// 视野首卡：与视野相交的最上一行里序号最小的卡片，网格的滚动锚点与键盘选择的起点都取它。
    ///
    /// 直接问排版视野里有哪些卡片，不看已准备的卡片：跳转后的视野可能还没有准备好的卡片。
    func firstVisibleItem() -> NSCollectionViewLayoutAttributes? {
        collectionViewLayout?.layoutAttributesForElements(in: visibleRect)
            .filter { $0.representedElementCategory == .item && $0.indexPath != nil }
            .min {
                ($0.frame.minY, $0.indexPath?.item ?? 0) < ($1.frame.minY, $1.indexPath?.item ?? 0)
            }
    }

    func refreshPreparedContentIfNeeded() {
        guard
            window != nil,
            NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: preparedContentRect,
                visible: visibleRect,
                bounds: bounds
            )
        else { return }
        prepareContent(in: visibleRect)
    }

    override func mouseDown(with event: NSEvent) {
        setShowsKeyboardSelection(false)
        let point = convert(event.locationInWindow, from: nil)
        let clickedIndexPath = indexPathForItem(at: point)
        super.mouseDown(with: event)
        guard
            let clickedIndexPath,
            let id = item(at: clickedIndexPath)?.representedObject as? String
        else { return }
        onActivateSelection?(id)
    }

    override func keyDown(with event: NSEvent) {
        if NativeVideoCollectionKeys.isActivation(event),
            let indexPath = selectionIndexPaths.first,
            let id = item(at: indexPath)?.representedObject as? String
        {
            onActivateSelection?(id)
            return
        }
        if let delta = NativeVideoCollectionKeys.selectionDelta(
            for: event,
            rowLength: NativeVideoGridGeometry.columnCount(for: bounds.width)
        ), numberOfItems(inSection: 0) > 0 {
            let visibleStart = firstVisibleItem()?.indexPath?.item ?? 0
            let current = selectionIndexPaths.first?.item ?? visibleStart
            selectWithKeyboard(itemAt: current + delta, scrollPosition: .nearestVerticalEdge)
            return
        }
        super.keyDown(with: event)
    }
}
