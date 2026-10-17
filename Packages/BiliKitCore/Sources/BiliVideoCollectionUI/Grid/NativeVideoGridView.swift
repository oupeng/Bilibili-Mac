import AppKit
import BiliUI
import SwiftUI

/// 首页推荐、热门、搜索与历史共用的原生视频网格，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 调用方是 Browse 与 Library 的网格包装，所以是 `package`。只渲染调用方给的卡片、尾部状态与回顶请求；
/// 内容、分页与选择的意图归调用方，滚动位置、回顶请求与取图 port 来自 App 窗口的
/// `NativeVideoGridHostContext`。滚动位置经 binding 双向同步，回顶请求经 `scrollReset` 握手确认。
package struct NativeVideoGridView: NSViewRepresentable {
    let items: [NativeVideoCardPresentation]
    @Binding var scrollOffsetY: CGFloat
    let accessibilityLabel: String
    let tailState: NativeVideoGridTailState
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: any NativeVideoImageLoading
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    package init(
        items: [NativeVideoCardPresentation],
        accessibilityLabel: String,
        tailState: NativeVideoGridTailState,
        host: NativeVideoGridHostContext,
        onNearEnd: @escaping () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.items = items
        _scrollOffsetY = host.scrollOffsetY
        self.accessibilityLabel = accessibilityLabel
        self.tailState = tailState
        _scrollReset = host.scrollReset
        imagePipeline = host.imageLoader
        self.onNearEnd = onNearEnd
        self.onSelect = onSelect
    }

    package func makeCoordinator() -> Coordinator {
        Coordinator(
            items: items,
            initialScrollOffsetY: scrollOffsetY,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            scrollResetRequestID: scrollReset.requestID,
            acknowledgedScrollResetRequestID: scrollReset.acknowledgedRequestID,
            imagePipeline: imagePipeline,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            onNearEnd: onNearEnd,
            onSelect: onSelect
        )
    }

    package func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    package func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(
            items: items,
            accessibilityLabel: accessibilityLabel,
            tailState: tailState,
            scrollResetRequestID: scrollReset.requestID,
            requestedScrollOffsetY: scrollOffsetY,
            onScroll: { scrollOffsetY = $0 },
            onAcknowledgeScrollReset: {
                scrollReset.acknowledgedRequestID = $0
            },
            onNearEnd: onNearEnd,
            onSelect: onSelect
        )
    }

    package static func dismantleNSView(
        _ view: NSScrollView,
        coordinator: Coordinator
    ) {
        coordinator.reset()
    }

    /// 网格的唯一 owner：滚动视图、集合视图、diffable 数据源、通知观察、悬停与滚动／分页状态。
    ///
    /// 不拥有图片管线（由窗口关闭）。`dismantleNSView` 调 `reset()`：先记录并同步最后的滚动位置（置位
    /// `isReset` 后 `persistScrollOffset` 直接返回），再推进 `updateEpoch` 作废在途快照回调、移除观察并清空
    /// 回调。之后 `update`、滚动与翻页判断按 `isReset` 返回；已排队的预备区域刷新靠 `window != nil` 兜底。
    @MainActor
    package final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout {
        private let scrollView = NativeVideoGridScrollView()
        private let collectionView = NativeVideoCollectionView()
        private let layout = NSCollectionViewFlowLayout()
        private let imagePipeline: any NativeVideoImageLoading
        private var dataSource: NSCollectionViewDiffableDataSource<Int, String>?
        private var contents: NativeVideoCardContents
        private var accessibilityLabel: String
        private var tailState: NativeVideoGridTailState
        /// 以已确认的回顶 ID 起步，每个新的 `requestID` 只消费一次：网格重建后仍会执行未确认的请求。
        private var scrollResetGate: NativeVideoGridScrollResetGate
        private var nearEndPagination = NearEndPagination<String>(
            tailChangeInsideThreshold: .rearms
        )
        private var onScroll: (CGFloat) -> Void
        private var onAcknowledgeScrollReset: (UInt64) -> Void
        private var onNearEnd: () -> Void
        private var onSelect: (String) -> Void
        private var observers = NativeVideoNotificationObservers()
        /// 待应用的逻辑偏移：初次恢复、回顶请求、外部请求，以及整体替换时 `topPin` 保持置顶或锚点卡片已不在
        /// 新内容里（后两者都回到 0）；视口可渲染时应用并清空，非 nil 期间不记录滚动、不判断翻页。
        private var pendingRestoreOffsetY: CGFloat?
        /// 回顶真正落地后才经 `onAcknowledgeScrollReset` 确认的请求 ID；非 nil 时忽略外部偏移请求。
        private var pendingScrollResetAcknowledgementID: UInt64?
        private var retainedScrollOffset: NativeVideoScrollOffsetRetention
        private var scrollBindingBridge: NativeVideoScrollBindingBridge
        private let hover = NativeVideoHoverTracker()
        /// 最近一次可渲染的视口尺寸；nil 表示当前没有可渲染的排版（初次、视口过窄或已拆除），锚点、恢复与
        /// 翻页判断都等它。
        private var lastViewportSize: NSSize?
        private var documentLayoutNeedsInvalidation = true
        /// 内容身份变化的每次快照与 `reset()` 都推进；快照完成回调只在仍是最新一次时执行。
        private var updateEpoch = NativeVideoGridOperationEpoch()
        /// 整体替换前记下的可见首卡及当时的 `scrollGeneration`；快照完成时只在其间没再滚动、也不在实时
        /// 滚动时恢复。
        private var pendingViewportAnchor: NativeVideoGridViewportAnchor?
        private var pendingAnchorScrollGeneration: UInt64?
        /// 不在程序设置偏移、也没有待恢复偏移时，每记录一次 bounds 变化就加一（含用户滚动、AppKit 因
        /// document 尺寸变化的夹取与 `reset()` 时的记录）；锚点恢复与 `topPin` 用它判断其间是否又有滚动。
        private var scrollGeneration: UInt64 = 0
        private var topPin = NativeVideoGridTopPin()
        /// 程序设置偏移期间为 true，让随之而来的 bounds 通知不被记成用户滚动。
        private var isApplyingRestoration = false
        private var isLiveScrolling = false
        /// 重排 document 期间为 true：其间到来的视口回调不再重排，也不判断翻页。
        private var isResizingDocument = false
        private var isReset = false

        init(
            items: [NativeVideoCardPresentation],
            initialScrollOffsetY: CGFloat,
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            scrollResetRequestID: UInt64,
            acknowledgedScrollResetRequestID: UInt64,
            imagePipeline: any NativeVideoImageLoading,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            contents = NativeVideoCardContents(items)
            self.accessibilityLabel = accessibilityLabel
            self.tailState = tailState
            scrollResetGate = NativeVideoGridScrollResetGate(
                initialRequestID: acknowledgedScrollResetRequestID
            )
            self.imagePipeline = imagePipeline
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            retainedScrollOffset = NativeVideoScrollOffsetRetention(
                initialOffsetY: initialScrollOffsetY
            )
            scrollBindingBridge = NativeVideoScrollBindingBridge(
                initialOffsetY: initialScrollOffsetY
            )
            pendingRestoreOffsetY = retainedScrollOffset.offsetY
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
            }
        }

        func makeScrollView() -> NSScrollView {
            let padding = NativeVideoGridGeometry.contentPadding
            layout.minimumInteritemSpacing = NativeVideoGridGeometry.horizontalSpacing
            layout.minimumLineSpacing = NativeVideoGridGeometry.verticalSpacing
            layout.sectionInset = NSEdgeInsets(
                top: NativeVideoGridGeometry.topContentPadding,
                left: padding,
                bottom: padding,
                right: padding
            )
            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.onSelect(id)
            }
            collectionView.register(
                NativeVideoCollectionItem.self,
                forItemWithIdentifier: .nativeVideoCard
            )

            dataSource = NativeVideoCardDataSource.make(
                collectionView: collectionView,
                presentation: { [weak self] id in self?.contents[id] },
                configure: { [weak self] item, presentation in
                    self?.configure(item, with: presentation)
                },
                showsKeyboardSelection: { [weak collectionView] in
                    collectionView?.showsKeyboardSelection == true
                }
            )

            scrollView.documentView = collectionView
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.onViewportLayout = { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
                self?.viewportDidChange()
            }
            scrollView.onContentInsetsChange = { [weak self] oldInsets, newInsets in
                self?.contentInsetsDidChange(from: oldInsets, to: newInsets)
            }
            collectionView.setAccessibilityLabel(accessibilityLabel)

            observers.observeScrolling(of: scrollView) { [weak self] in self?.didScroll() }
            observers.observe(
                NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = false
                self?.persistScrollOffset()
            }
            observers.observe(
                NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            ) { [weak self] in
                self?.isLiveScrolling = true
                self?.nearEndPagination.releaseBackpressure()
            }
            observers.observeAccessibilityDisplayOptions { [weak collectionView] in
                collectionView?.refreshVisibleCardAppearance()
            }

            applySnapshot()
            // 返回时滚动视图还没装进 SwiftUI 的层级；下一轮再排版、恢复位置并判断翻页。
            DispatchQueue.main.async { [weak self] in
                self?.resizeDocument()
                self?.restorePendingOffsetIfPossible()
                self?.viewportDidChange()
            }
            return scrollView
        }

        func update(
            items: [NativeVideoCardPresentation],
            accessibilityLabel: String,
            tailState: NativeVideoGridTailState,
            scrollResetRequestID: UInt64,
            requestedScrollOffsetY: CGFloat,
            onScroll: @escaping (CGFloat) -> Void,
            onAcknowledgeScrollReset: @escaping (UInt64) -> Void,
            onNearEnd: @escaping () -> Void,
            onSelect: @escaping (String) -> Void
        ) {
            guard !isReset else { return }
            self.onScroll = onScroll
            self.onAcknowledgeScrollReset = onAcknowledgeScrollReset
            self.onNearEnd = onNearEnd
            self.onSelect = onSelect
            self.tailState = tailState
            // binding 每次都先交给 bridge：滤掉网格刚同步出去的当前值的回声，以及同一轮更新里交回的、
            // 被它替换掉的上一个值（`supersededOffsetY`）。回顶请求优先于外部偏移。
            let requestedExternalOffset = scrollBindingBridge.takeExternalRequest(
                requestedScrollOffsetY
            )
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
                pendingViewportAnchor = nil
                pendingAnchorScrollGeneration = nil
            } else if pendingScrollResetAcknowledgementID == nil,
                let requestedExternalOffset
            {
                pendingRestoreOffsetY = requestedExternalOffset
                pendingViewportAnchor = nil
                pendingAnchorScrollGeneration = nil
            }
            if self.accessibilityLabel != accessibilityLabel {
                self.accessibilityLabel = accessibilityLabel
                collectionView.setAccessibilityLabel(accessibilityLabel)
            }

            let updatedContents = NativeVideoCardContents(items)
            let updatePlan = NativeVideoGridUpdatePlan(
                previousIDs: contents.orderedIDs,
                previousContents: contents.byID,
                updatedIDs: updatedContents.orderedIDs,
                updatedContents: updatedContents.byID
            )
            if updatePlan.restoresViewportAnchor,
                pendingRestoreOffsetY == nil,
                pendingViewportAnchor == nil
            {
                if topPin.keepsTop(atScrollGeneration: scrollGeneration) {
                    pendingRestoreOffsetY = 0
                } else if let anchor = captureViewportAnchor() {
                    if updatePlan.retains(anchor) {
                        pendingViewportAnchor = anchor
                        pendingAnchorScrollGeneration = scrollGeneration
                    } else {
                        // 停在旧偏移会被新内容高度截断到新内容底部，还会据此误判翻页。
                        pendingRestoreOffsetY = 0
                    }
                }
            }
            contents = updatedContents

            if updatePlan.identityChanged, !updatePlan.isStrictTailAppend {
                // 内容整体替换后，旧手势留下的背压不再适用。
                nearEndPagination.releaseBackpressure()
            }
            if updatePlan.identityChanged {
                let operationGeneration = updateEpoch.advance()
                let capturedScrollGeneration = scrollGeneration
                documentLayoutNeedsInvalidation = true
                applySnapshot { [weak self] in
                    guard
                        let self,
                        !self.isReset,
                        self.updateEpoch.accepts(operationGeneration)
                    else { return }
                    self.reconfigureVisibleItems()
                    let anchor = self.pendingViewportAnchor
                    let anchorScrollGeneration = self.pendingAnchorScrollGeneration
                    self.pendingViewportAnchor = nil
                    self.pendingAnchorScrollGeneration = nil
                    if self.pendingRestoreOffsetY != nil {
                        self.resizeDocument(restoringViewport: false)
                        self.restorePendingOffsetIfPossible()
                    } else if anchor != nil,
                        !self.isLiveScrolling,
                        self.scrollGeneration
                            == (anchorScrollGeneration ?? capturedScrollGeneration)
                    {
                        self.resizeDocument(anchor: anchor)
                        self.restorePendingOffsetIfPossible()
                    } else {
                        self.resizeDocument(restoringViewport: false)
                    }
                    self.viewportDidChange()
                }
            } else if !updatePlan.changedExistingIDs.isEmpty {
                reconfigureVisibleItems(updatePlan.changedExistingIDs)
            }

            if !updatePlan.identityChanged {
                restorePendingOffsetIfPossible()
                viewportDidChange()
            }
        }

        func reset() {
            guard !isReset else { return }
            recordCurrentScrollOffset(requireAttachedWindow: false)
            persistScrollOffset()
            isReset = true
            _ = updateEpoch.advance()
            hover.forgetHoveredItem()
            for item in collectionView.visibleVideoCards { item.invalidate() }
            collectionView.onActivateSelection = nil
            scrollView.onViewportLayout = nil
            scrollView.onContentInsetsChange = nil
            collectionView.delegate = nil
            collectionView.dataSource = nil
            dataSource = nil
            observers.removeAll()
            onScroll = { _ in }
            onAcknowledgeScrollReset = { _ in }
            onNearEnd = {}
            onSelect = { _ in }
            lastViewportSize = nil
            contents = NativeVideoCardContents()
            nearEndPagination.reset()
            pendingViewportAnchor = nil
            pendingAnchorScrollGeneration = nil
        }

        /// 不做差异动画：动画期间新卡片要等动画结束才创建，而整体替换紧接着回顶，视野会空白一段。
        private func applySnapshot(completion: (() -> Void)? = nil) {
            dataSource?.apply(
                contents.makeSnapshot(),
                animatingDifferences: false,
                completion: completion
            )
        }

        private func reconfigureVisibleItems(_ ids: Set<String>? = nil) {
            for (item, presentation) in contents.visibleCards(in: collectionView, ids: ids) {
                configure(item, with: presentation)
            }
        }

        private func configure(
            _ item: NativeVideoCollectionItem,
            with presentation: NativeVideoCardPresentation
        ) {
            item.configure(
                presentation: presentation,
                imagePipeline: imagePipeline,
                hoverChanged: { [weak self] item, isHovered in
                    self?.item(item, didChangeHover: isHovered)
                },
                activation: { [weak self, weak collectionView] selectedID in
                    if let indexPath = self?.contents.indexPath(of: selectedID) {
                        collectionView?.selectionIndexPaths = [indexPath]
                    }
                    self?.onSelect(selectedID)
                }
            )
        }

        /// `restoringViewport` 为 false 时无条件重排 document，且不恢复语义 anchor。
        private func resizeDocument(
            restoringViewport: Bool = true,
            anchor suppliedAnchor: NativeVideoGridViewportAnchor? = nil
        ) {
            guard !isReset, !isResizingDocument else { return }
            let viewportSize = scrollView.contentSize
            guard NativeVideoGridGeometry.isRenderableViewport(width: viewportSize.width)
            else {
                lastViewportSize = nil
                documentLayoutNeedsInvalidation = true
                return
            }
            isResizingDocument = true
            defer { isResizingDocument = false }
            let anchor = restoringViewport ? suppliedAnchor ?? captureViewportAnchor() : nil
            let width = viewportSize.width
            let widthChanged =
                lastViewportSize.map {
                    abs($0.width - viewportSize.width) > 0.5
                } ?? true
            let heightChanged =
                lastViewportSize.map {
                    abs($0.height - viewportSize.height) > 0.5
                } ?? true
            let shouldInvalidateLayout =
                !restoringViewport || documentLayoutNeedsInvalidation || widthChanged
            guard shouldInvalidateLayout || heightChanged else { return }

            lastViewportSize = viewportSize
            documentLayoutNeedsInvalidation = false
            let contentHeight = NativeVideoGridGeometry.contentHeight(
                for: width,
                itemCount: contents.orderedIDs.count
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            if shouldInvalidateLayout { layout.invalidateLayout() }
            collectionView.layoutSubtreeIfNeeded()
            restore(anchor)
        }

        private var currentScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private var minimumPhysicalScrollOffsetY: CGFloat {
            -max(0, scrollView.contentInsets.top)
        }

        private var maximumLogicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: collectionView.frame.height,
                viewportLength: scrollView.contentSize.height,
                leadingInset: scrollView.contentInsets.top,
                trailingInset: scrollView.contentInsets.bottom
            )
        }

        private var maximumPhysicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: maximumLogicalScrollOffsetY,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private func didScroll() {
            guard
                !isReset,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return }
            hover.updateForCurrentPointerLocation(in: collectionView)
            recordCurrentScrollOffset(requireAttachedWindow: true)
            viewportDidChange()
        }

        @discardableResult
        private func recordCurrentScrollOffset(requireAttachedWindow: Bool) -> Bool {
            guard
                !isApplyingRestoration,
                pendingRestoreOffsetY == nil,
                !requireAttachedWindow || scrollView.window != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                )
            else { return false }
            retainedScrollOffset.record(currentScrollOffsetY)
            scrollGeneration &+= 1
            return true
        }

        private func persistScrollOffset() {
            guard !isReset else { return }
            guard let offsetY = retainedScrollOffset.takePendingPersistence() else {
                return
            }
            synchronizeBinding(to: offsetY)
        }

        private func contentInsetsDidChange(
            from oldInsets: NSEdgeInsets,
            to newInsets: NSEdgeInsets
        ) {
            guard !isReset else { return }
            if pendingRestoreOffsetY != nil {
                restorePendingOffsetIfPossible()
                viewportDidChange()
                return
            }
            let logicalOffset = NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: oldInsets.top
            )
            applyLogicalScrollOffset(logicalOffset, synchronizingBinding: false)
            retainedScrollOffset.markPersisted(logicalOffset)
        }

        private func captureViewportAnchor() -> NativeVideoGridViewportAnchor? {
            guard
                !contents.orderedIDs.isEmpty,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return nil }
            let visibleTop = collectionView.visibleRect.minY
            let candidates = collectionView.indexPathsIntersectingVisibleRect().compactMap {
                indexPath -> (IndexPath, NSCollectionViewLayoutAttributes)? in
                guard let attributes = layout.layoutAttributesForItem(at: indexPath) else {
                    return nil
                }
                return (indexPath, attributes)
            }
            guard let first = candidates.min(by: { $0.1.frame.minY < $1.1.frame.minY }),
                contents.orderedIDs.indices.contains(first.0.item)
            else { return nil }
            return NativeVideoGridViewportAnchor(
                id: contents.orderedIDs[first.0.item],
                offsetFromViewportTop: first.1.frame.minY - visibleTop
            )
        }

        private func restore(_ anchor: NativeVideoGridViewportAnchor?) {
            guard
                let anchor,
                let index = contents.orderedIDs.firstIndex(of: anchor.id),
                let attributes = layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                )
            else { return }
            let target = NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: attributes.frame.minY,
                offsetFromViewportTop: anchor.offsetFromViewportTop,
                minimumOffsetY: minimumPhysicalScrollOffsetY,
                maximumOffsetY: maximumPhysicalScrollOffsetY
            )
            applyPhysicalScrollOffset(target)
        }

        private func restorePendingOffsetIfPossible() {
            guard
                !isReset,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: scrollView.contentSize.width
                ),
                let pendingRestoreOffsetY
            else { return }
            let target = min(pendingRestoreOffsetY, maximumLogicalScrollOffsetY)
            applyLogicalScrollOffset(target, synchronizingBinding: false)
            self.pendingRestoreOffsetY = nil
            if target <= 0 {
                topPin.pin(atScrollGeneration: scrollGeneration)
            }
            retainedScrollOffset.markPersisted(target)
            synchronizeBinding(to: target)
            if let acknowledgementID = pendingScrollResetAcknowledgementID {
                pendingScrollResetAcknowledgementID = nil
                onAcknowledgeScrollReset(acknowledgementID)
            }
        }

        private func applyLogicalScrollOffset(
            _ target: CGFloat,
            synchronizingBinding: Bool
        ) {
            let logicalTarget = min(max(0, target), maximumLogicalScrollOffsetY)
            let physicalTarget = NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: logicalTarget,
                leadingInset: scrollView.contentInsets.top
            )
            applyPhysicalScrollOffset(physicalTarget)
            retainedScrollOffset.markPersisted(logicalTarget)
            if synchronizingBinding { synchronizeBinding(to: logicalTarget) }
        }

        private func synchronizeBinding(to offsetY: CGFloat) {
            scrollBindingBridge.markSynchronized(offsetY)
            onScroll(offsetY)
        }

        private func applyPhysicalScrollOffset(_ target: CGFloat) {
            isApplyingRestoration = true
            scrollView.scrollVertically(toPhysicalOffset: target)
            isApplyingRestoration = false
        }

        /// 视野或内容变化后：先保持封面预加载的余量，再判断是否请求下一页。
        private func viewportDidChange() {
            collectionView.refreshPreparedContentIfNeeded()
            evaluateNearEnd()
        }

        /// 重排 document 或等待恢复偏移时视口还在过渡：条目数已是新的，位置还是旧的，此时不判断翻页。
        private func evaluateNearEnd() {
            guard
                !isReset,
                !isResizingDocument,
                pendingRestoreOffsetY == nil,
                lastViewportSize != nil,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return }
            let isInside =
                tailState.canLoadMore && tailState.tailIdentity != nil
                && NativeVideoGridGeometry.isNearEnd(
                    itemCount: contents.orderedIDs.count,
                    width: collectionView.bounds.width,
                    visibleMaximumY: collectionView.visibleRect.maxY,
                    viewportHeight: collectionView.visibleRect.height
                )
            if nearEndPagination.shouldLoadMore(
                isInsideThreshold: isInside,
                state: tailState,
                isLiveScrolling: isLiveScrolling
            ) {
                onNearEnd()
            }
        }

        private func item(
            _ item: NativeVideoCollectionItem,
            didChangeHover isHovered: Bool
        ) {
            guard !isReset else { return }
            hover.itemDidChangeHover(item, isHovered: isHovered)
        }

        package func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> NSSize {
            NativeVideoGridGeometry.itemSize(for: collectionView.bounds.width)
        }

        package func collectionView(
            _ collectionView: NSCollectionView,
            didEndDisplaying item: NSCollectionViewItem,
            forRepresentedObjectAt indexPath: IndexPath
        ) {
            guard let item = item as? NativeVideoCollectionItem else { return }
            guard collectionView.indexPath(for: item) == nil else { return }
            hover.itemDidEndDisplaying(item)
        }
    }
}

/// 网格的滚动视图：在 `layout()` 里报告视口尺寸与 contentInsets 的变化，由 Coordinator 重排与保持位置。
@MainActor
private final class NativeVideoGridScrollView: NSScrollView {
    var onViewportLayout: (() -> Void)?
    var onContentInsetsChange: ((NSEdgeInsets, NSEdgeInsets) -> Void)?
    private var viewportTracker = NativeScrollViewportTracker()

    override func layout() {
        super.layout()
        let change = viewportTracker.update(for: self)
        if let previousInsets = change.previousInsets {
            onContentInsetsChange?(previousInsets, contentInsets)
        }
        if change.sizeChanged { onViewportLayout?() }
    }
}

/// 网格的集合视图：扩大预备区域，并处理点击激活与按列数移动的键盘选择。
@MainActor
private final class NativeVideoCollectionView: NativeVideoCardCollectionView {
    /// AppKit 默认只准备视野内的卡片，封面要等卡片露出来才开始加载；这里上下各多准备一屏。
    ///
    /// 因此 `indexPathsForVisibleItems()` 也包含视野外已准备的卡片；需要“看得见的卡片”时用
    /// `indexPathsIntersectingVisibleRect()`。
    override func prepareContent(in rect: NSRect) {
        guard !visibleRect.isEmpty else {
            super.prepareContent(in: rect)
            return
        }
        super.prepareContent(
            in: NativeVideoGridGeometry.preparedContentRect(visible: visibleRect, bounds: bounds)
        )
    }

    /// 与视野相交的卡片：键盘选择的起点与滚动锚点只能取用户看得见的卡片。
    func indexPathsIntersectingVisibleRect() -> [IndexPath] {
        let visible = visibleRect
        return indexPathsForVisibleItems().filter {
            collectionViewLayout?.layoutAttributesForItem(at: $0)?.frame.intersects(visible) == true
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
            let visibleStart = indexPathsIntersectingVisibleRect().map(\.item).min() ?? 0
            let current = selectionIndexPaths.first?.item ?? visibleStart
            selectWithKeyboard(itemAt: current + delta, scrollPosition: .nearestVerticalEdge)
            return
        }
        super.keyDown(with: event)
    }
}
