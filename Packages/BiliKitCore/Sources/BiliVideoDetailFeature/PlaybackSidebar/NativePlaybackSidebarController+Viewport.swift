import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 视口：语义锚点的捕获与恢复、宽度变化后的分批精测、回到顶部与跳到评论区。
extension NativePlaybackSidebarController {
    func viewportSizeDidChange(_ size: CGSize) {
        guard !isTornDown, size.width > 0,
            abs(size.width - measuredViewportWidth) > 0.5
        else { return }
        cancelRefinement()
        let anchor = captureAnchor()
        measuredViewportWidth = size.width
        collectionView.frame.size.width = size.width
        layout.invalidateLayout()
        collectionView.layoutSubtreeIfNeeded()
        synchronizeDocumentFrame()
        if let anchor {
            restore(anchor)
        }
        scheduleRefinement()
    }

    /// 语义锚点：视野内最靠上的条目及其顶边到视口顶边的距离，或者视口贴底。
    ///
    /// 布局变化（追加、改宽度、精测）前捕获，变化后按条目的新位置恢复，阅读位置不随上方内容的高度变化跳动。
    struct Anchor {
        let itemID: NativePlaybackSidebarItemID
        let relativeY: CGFloat
        let wasPinnedToBottom: Bool
    }

    func captureAnchor(
        allowsBottomFollowing: Bool = true
    ) -> Anchor? {
        collectionView.layoutSubtreeIfNeeded()
        let viewport = rootView.scrollView.documentVisibleRect
        let wasPinnedToBottom =
            allowsBottomFollowing
            && NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: layout.collectionViewContentSize.height,
                viewport: viewport
            )
        return collectionView.indexPathsForVisibleItems()
            .compactMap { indexPath -> (NativePlaybackSidebarItemID, NSRect)? in
                guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                    let attributes = layout.layoutAttributesForItem(at: indexPath),
                    attributes.frame.intersects(viewport)
                else { return nil }
                return (itemID, attributes.frame)
            }
            .sorted { $0.1.minY < $1.1.minY }
            .first
            .map {
                Anchor(
                    itemID: $0.0,
                    relativeY: $0.1.minY - viewport.minY,
                    wasPinnedToBottom: wasPinnedToBottom
                )
            }
    }

    func restore(_ anchor: Anchor) {
        if anchor.wasPinnedToBottom {
            scrollToBottom()
            return
        }
        guard let indexPath = dataSource?.indexPath(for: anchor.itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return }
        let physicalOffset = attributes.frame.minY - anchor.relativeY
        scroll(
            to: NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: physicalOffset,
                leadingInset: rootView.scrollView.contentInsets.top
            )
        )
    }

    func synchronizeDocumentFrame() {
        let size = NSSize(
            width: rootView.scrollView.contentSize.width,
            height: max(
                rootView.scrollView.contentSize.height,
                layout.collectionViewContentSize.height
            )
        )
        guard collectionView.frame.size != size else { return }
        collectionView.setFrameSize(size)
    }

    private func scrollToTop() {
        scroll(to: 0)
    }

    private func scrollToBottom() {
        scroll(to: layout.collectionViewContentSize.height)
    }

    func cancelRefinement() {
        refinement.cancel()
    }

    /// 按批精测估算行高，每批之后恢复锚点并让出 main actor，长评论列表的重测不会一次卡住界面。
    ///
    /// 优先精测锚点所在的行；代次不再相等（被取消或重新安排）、拆除或没有待精测的行时停止。
    func scheduleRefinement() {
        guard !isTornDown, !layout.pendingRefinementIndexes.isEmpty else {
            return
        }
        refinement.start { [weak self] in
            guard let self, !self.isTornDown,
                !self.layout.pendingRefinementIndexes.isEmpty
            else { return false }
            let anchor = self.captureAnchor()
            guard
                self.layout.refineNextBatch(
                    maximumCount: NativePlaybackSidebarLayout.refinementBatchSize,
                    prioritizing: anchor?.itemID
                )
            else { return false }
            self.collectionView.layoutSubtreeIfNeeded()
            self.synchronizeDocumentFrame()
            if let anchor { self.restore(anchor) }
            return true
        }
    }

    private func scrollToCommentsHeader() {
        guard
            let itemID = itemIDs.first(where: {
                if case .commentsHeader = $0 { return true }
                return false
            }), let indexPath = dataSource?.indexPath(for: itemID),
            let attributes = layout.layoutAttributesForItem(at: indexPath)
        else { return }
        scroll(to: attributes.frame.minY)
    }

    func applyPendingViewportIntent(fallbackAnchor: Anchor?) {
        if pendingResetToTop {
            pendingResetToTop = false
            pendingScrollToComments = false
            scrollToTop()
        } else if pendingScrollToComments {
            pendingScrollToComments = false
            scrollToCommentsHeader()
        } else if let fallbackAnchor {
            restore(fallbackAnchor)
        }
    }

    func updateTopButton() {
        rootView.scrollView.updateTopButtonVisibility(
            isBlocked: presentation.overlay.blocksContent
        )
    }

    /// “返回顶部”回到侧栏最上面（UP 主信息），而不只是评论区。
    @objc func scrollToTopFromButton() {
        scroll(to: 0, animated: true)
    }

    /// 只有用户点“返回顶部”时 `animated` 为 true；其余程序内部定位直接跳转。
    func scroll(to y: CGFloat, animated: Bool = false) {
        synchronizeDocumentFrame()
        let maximumY = NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
            documentLength: layout.collectionViewContentSize.height,
            viewportLength: rootView.scrollView.contentSize.height,
            leadingInset: rootView.scrollView.contentInsets.top,
            trailingInset: rootView.scrollView.contentInsets.bottom
        )
        let logicalTarget = min(max(0, y), maximumY)
        rootView.scrollView.scrollVertically(
            toPhysicalOffset: NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalTarget,
                leadingInset: rootView.scrollView.contentInsets.top
            ),
            animated: animated
        )
    }

    func viewportDidScroll() {
        updateTopButton()
        scheduleNextCommentsPageIfNeeded()
    }
}
