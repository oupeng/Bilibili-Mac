import AppKit
import BiliUI
import SwiftUI

/// 首页推荐、热门、搜索、观看历史、稍后再看与收藏夹共用的原生视频网格，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」。
///
/// 调用方是 Browse 与 Library 的网格包装，所以是 `package`。只渲染调用方给的卡片、尾部状态与回顶请求；
/// 内容、分页与选择的意图归调用方，滚动位置、回顶请求与取图 port 来自 App 窗口的
/// `NativeVideoGridHostContext`。滚动位置经 binding 双向同步，回顶请求经 `scrollReset` 握手确认。
/// 不可用卡片（`NativeVideoCardAvailability.unavailable`）不能被鼠标选中或按下高亮，点击、回车、空格与读屏按下都不回调
/// `onSelect`；键盘方向键仍可把选择停在上面。`bottomInset` 是末行下方为悬浮控件（收藏夹的页码条）额外留出的高度，
/// 布局与内容高度共用这个值。
package struct NativeVideoGridView: NSViewRepresentable {
    let items: [NativeVideoCardPresentation]
    @Binding var scrollOffsetY: CGFloat
    let accessibilityLabel: String
    let tailState: NativeVideoGridTailState
    let bottomInset: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: any NativeVideoImageLoading
    let onNearEnd: () -> Void
    let onSelect: (String) -> Void

    package init(
        items: [NativeVideoCardPresentation],
        accessibilityLabel: String,
        tailState: NativeVideoGridTailState,
        bottomInset: CGFloat = 0,
        host: NativeVideoGridHostContext,
        onNearEnd: @escaping () -> Void,
        onSelect: @escaping (String) -> Void
    ) {
        self.items = items
        _scrollOffsetY = host.scrollOffsetY
        self.accessibilityLabel = accessibilityLabel
        self.tailState = tailState
        self.bottomInset = bottomInset
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
            bottomInset: bottomInset,
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
            bottomInset: bottomInset,
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
        /// 末行下方额外留出的高度；变化时重排 document。
        private var bottomInset: CGFloat
        /// 以已确认的回顶 ID 起步，每个新的 `requestID` 只消费一次：网格重建后仍会执行未确认的请求。
        private var scrollResetGate: NativeVideoGridScrollResetGate
        private var nearEndPagination = NearEndPagination<UInt64>(
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
        /// 用户最后看到的视野首卡，宽度变化、高度变化与整体替换都按它恢复位置，恢复后不重新捕获（理由见
        /// ARCHITECTURE「网格的视口锚点」）。
        ///
        /// 捕获点：记录到一次滚动（不在宽度过渡或重排 document 中）、应用待恢复偏移、整体替换没能按它恢复，
        /// 以及它缺失或卡片已不在内容里时在重排结束后补捕。`reset()` 清空。
        private var viewportAnchor: NativeVideoGridViewportAnchor?
        /// 整体替换要按 `viewportAnchor` 恢复时记下的 `scrollGeneration`；快照完成时只在其间没再滚动、也不在
        /// 实时滚动时恢复，否则重新捕获锚点。
        private var pendingAnchorScrollGeneration: UInt64?
        /// 不在程序设置偏移、也没有待恢复偏移时，每记录一次 bounds 变化就加一（含用户滚动、重排 document 时
        /// AppKit 的夹取与 `reset()` 时的记录；宽度过渡中的 bounds 变化不记录）；锚点恢复与 `topPin` 用它判断其间是否又有滚动。
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
            bottomInset: CGFloat,
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
            self.bottomInset = bottomInset
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
            layout.minimumInteritemSpacing = NativeVideoGridGeometry.horizontalSpacing
            layout.minimumLineSpacing = NativeVideoGridGeometry.verticalSpacing
            layout.sectionInset = sectionInset
            collectionView.collectionViewLayout = layout
            collectionView.delegate = self
            collectionView.isSelectable = true
            collectionView.allowsMultipleSelection = false
            collectionView.backgroundColors = [.clear]
            collectionView.onActivateSelection = { [weak self] id in
                self?.activate(id)
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
            bottomInset: CGFloat,
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
            if self.bottomInset != bottomInset {
                self.bottomInset = bottomInset
                layout.sectionInset = sectionInset
                documentLayoutNeedsInvalidation = true
                resizeDocument()
            }
            // binding 每次都先交给 bridge：滤掉网格刚同步出去的当前值的回声，以及同一轮更新里交回的、
            // 被它替换掉的上一个值（`supersededOffsetY`）。回顶请求优先于外部偏移。
            let requestedExternalOffset = scrollBindingBridge.takeExternalRequest(
                requestedScrollOffsetY
            )
            if scrollResetGate.consume(scrollResetRequestID) {
                pendingRestoreOffsetY = 0
                pendingScrollResetAcknowledgementID = scrollResetRequestID
                pendingAnchorScrollGeneration = nil
            } else if pendingScrollResetAcknowledgementID == nil,
                let requestedExternalOffset
            {
                pendingRestoreOffsetY = requestedExternalOffset
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
                pendingAnchorScrollGeneration == nil
            {
                if topPin.keepsTop(atScrollGeneration: scrollGeneration) {
                    pendingRestoreOffsetY = 0
                } else if let anchor = viewportAnchor {
                    if updatePlan.retains(anchor) {
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
                documentLayoutNeedsInvalidation = true
                applySnapshot { [weak self] in
                    guard
                        let self,
                        !self.isReset,
                        self.updateEpoch.accepts(operationGeneration)
                    else { return }
                    self.reconfigureVisibleItems()
                    let anchorScrollGeneration = self.pendingAnchorScrollGeneration
                    self.pendingAnchorScrollGeneration = nil
                    if self.pendingRestoreOffsetY != nil {
                        self.resizeDocument(restoringViewport: false)
                        self.restorePendingOffsetIfPossible()
                    } else if let anchorScrollGeneration,
                        !self.isLiveScrolling,
                        self.scrollGeneration == anchorScrollGeneration
                    {
                        self.resizeDocument()
                    } else {
                        // 想按锚点恢复却被其间的滚动打断时，卡片已在原偏移下换了位置，锚点作废、重排后重新捕获；
                        // 严格尾部追加不移动已有卡片，锚点照旧。
                        if anchorScrollGeneration != nil { self.viewportAnchor = nil }
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
            viewportAnchor = nil
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
                activation: { [weak self] selectedID in
                    self?.activate(selectedID, selecting: true)
                }
            )
        }

        /// 网格激活的唯一入口：点击、回车／空格与读屏按下都经这里；不可用或已不在内容里的卡片不回调 `onSelect`。
        ///
        /// 读屏按下不经集合视图的选择，`selecting` 为 true 时先把选择移到这张卡片。
        private func activate(_ id: String, selecting: Bool = false) {
            guard !isReset, contents.isActivatable(id) else { return }
            if selecting, let indexPath = contents.indexPath(of: id) {
                collectionView.selectionIndexPaths = [indexPath]
            }
            onSelect(id)
        }

        /// 集合视图的 section 边距：底边是内容留白加上 `bottomInset`，与 `contentHeight` 同源。
        private var sectionInset: NSEdgeInsets {
            let padding = NativeVideoGridGeometry.contentPadding
            return NSEdgeInsets(
                top: NativeVideoGridGeometry.topContentPadding,
                left: padding,
                bottom: padding + bottomInset,
                right: padding
            )
        }

        /// `restoringViewport` 为 false 时无条件重排 document，且不按 `viewportAnchor` 恢复；锚点缺失或它的卡片已不在
        /// 内容里时，重排后从当前排版补捕。
        private func resizeDocument(restoringViewport: Bool = true) {
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
            let width = viewportSize.width
            let widthChanged = isAwaitingWidthLayout
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
                itemCount: contents.orderedIDs.count,
                bottomInset: bottomInset
            )
            collectionView.setFrameSize(
                NSSize(width: width, height: max(viewportSize.height, contentHeight))
            )
            if shouldInvalidateLayout { layout.invalidateLayout() }
            collectionView.layoutSubtreeIfNeeded()
            if restoringViewport { restore(viewportAnchor) }
            if viewportAnchor.map({ contents[$0.id] == nil }) ?? true {
                viewportAnchor = captureViewportAnchor()
            }
        }

        /// 视口宽度与最近一次排版不同（或还没有排版）：AppKit 已在 `onViewportLayout` 之前按新宽度、旧卡片尺寸
        /// 重排了集合视图，`resizeDocument` 按新宽度重排之前排版与偏移都不可信。
        private var isAwaitingWidthLayout: Bool {
            lastViewportSize.map {
                abs($0.width - scrollView.contentSize.width) > 0.5
            } ?? true
        }

        private var currentScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: scrollView.contentView.bounds.origin.y,
                leadingInset: scrollView.contentInsets.top
            )
        }

        private var maximumLogicalScrollOffsetY: CGFloat {
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: collectionView.frame.height,
                viewportLength: scrollView.contentSize.height,
                leadingInset: scrollView.contentInsets.top,
                trailingInset: scrollView.contentInsets.bottom
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
            // 宽度过渡中的 bounds 变化不记录、不捕获锚点、不判断翻页，随后的 `onViewportLayout` 按锚点恢复。
            guard !isAwaitingWidthLayout else { return }
            // 重排 document 时 AppKit 的夹取照常记录，但锚点留给随后的恢复，不从重排中的排版捕获。
            if recordCurrentScrollOffset(requireAttachedWindow: true), !isResizingDocument {
                viewportAnchor = captureViewportAnchor()
            }
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

        /// 从当前排版读出视野首卡；宽度过渡中（`isAwaitingWidthLayout`）读不出可信的首卡，返回 nil。
        private func captureViewportAnchor() -> NativeVideoGridViewportAnchor? {
            guard
                !contents.orderedIDs.isEmpty,
                !isAwaitingWidthLayout,
                NativeVideoGridGeometry.isRenderableViewport(
                    width: collectionView.bounds.width
                )
            else { return nil }
            // 直接问排版视野里有哪些卡片：跳转后的视野可能还没有准备好的卡片。同一行按序号取最靠前的一张，
            // 同一视野总是得到同一个锚点。
            let candidates = layout.layoutAttributesForElements(in: collectionView.visibleRect)
                .filter { $0.representedElementCategory == .item }
                .compactMap { attributes -> (item: Int, minY: CGFloat)? in
                    attributes.indexPath.map { ($0.item, attributes.frame.minY) }
                }
            guard
                let first = candidates.min(by: { ($0.minY, $0.item) < ($1.minY, $1.item) }),
                contents.orderedIDs.indices.contains(first.item)
            else { return nil }
            return NativeVideoGridViewportAnchor(
                id: contents.orderedIDs[first.item],
                offsetFromViewportTop: first.minY - currentScrollOffsetY
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
                maximumOffsetY: maximumLogicalScrollOffsetY
            )
            applyPhysicalScrollOffset(
                NativeVideoScrollCoordinateSpace.physicalOffset(
                    logicalOffset: target,
                    leadingInset: scrollView.contentInsets.top
                )
            )
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
            viewportAnchor = captureViewportAnchor()
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
                    viewportHeight: collectionView.visibleRect.height,
                    bottomInset: bottomInset
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

        /// 鼠标选中只接受可进入播放的卡片；键盘方向键直接设置选择、不经这里，焦点仍可停在不可用卡片上。
        package func collectionView(
            _ collectionView: NSCollectionView,
            shouldSelectItemsAt indexPaths: Set<IndexPath>
        ) -> Set<IndexPath> {
            contents.activatableIndexPaths(in: indexPaths)
        }

        /// 按下高亮只给可进入播放的卡片，其他高亮状态照常。
        package func collectionView(
            _ collectionView: NSCollectionView,
            shouldChangeItemsAt indexPaths: Set<IndexPath>,
            to highlightState: NSCollectionViewItem.HighlightState
        ) -> Set<IndexPath> {
            highlightState == .forSelection
                ? contents.activatableIndexPaths(in: indexPaths)
                : indexPaths
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
