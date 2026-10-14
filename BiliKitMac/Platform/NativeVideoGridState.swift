import AppKit
import BiliUI

typealias NativeVideoGridTailState = NearEndTailState<String>

struct NativeVideoGridUpdatePlan: Equatable {
    let identityChanged: Bool
    let insertedIDs: [String]
    let removedIDs: [String]
    let changedExistingIDs: Set<String>
    let isStrictTailAppend: Bool

    var restoresViewportAnchor: Bool { identityChanged && !isStrictTailAppend }

    /// 锚点卡片仍在更新后的内容里时才有位置可保持；它被替换掉时网格回到顶部。
    func retains(_ anchor: NativeVideoGridViewportAnchor) -> Bool {
        !removedIDs.contains(anchor.id)
    }

    init<Content: Equatable>(
        previousIDs: [String],
        previousContents: [String: Content],
        updatedIDs: [String],
        updatedContents: [String: Content]
    ) {
        identityChanged = previousIDs != updatedIDs
        let previousSet = Set(previousIDs)
        let updatedSet = Set(updatedIDs)
        insertedIDs = updatedIDs.filter { !previousSet.contains($0) }
        removedIDs = previousIDs.filter { !updatedSet.contains($0) }
        changedExistingIDs = Set(
            updatedIDs.filter {
                previousSet.contains($0) && previousContents[$0] != updatedContents[$0]
            }
        )
        isStrictTailAppend =
            updatedIDs.count > previousIDs.count
            && Array(updatedIDs.prefix(previousIDs.count)) == previousIDs
            && removedIDs.isEmpty
            && insertedIDs == Array(updatedIDs.dropFirst(previousIDs.count))
    }
}

struct NativeVideoGridScrollResetGate {
    private var requestID: UInt64

    init(initialRequestID: UInt64) {
        requestID = initialRequestID
    }

    mutating func consume(_ candidateRequestID: UInt64) -> Bool {
        guard candidateRequestID != requestID else { return false }
        requestID = candidateRequestID
        return true
    }
}

/// 程序把网格放回顶部之后、用户再次滚动之前，内容整体替换仍停在顶部。
///
/// 否则替换时会按旧内容第一张可见卡片做锚点恢复：刷新把新条目插到最前或把列表收回第一页时，
/// 那张卡片的位置变了，视口就被带离顶部。用户滚动会推进滚动代次，置顶随之失效。
struct NativeVideoGridTopPin: Equatable {
    private var pinnedScrollGeneration: UInt64?

    mutating func pin(atScrollGeneration generation: UInt64) {
        pinnedScrollGeneration = generation
    }

    func keepsTop(atScrollGeneration generation: UInt64) -> Bool {
        pinnedScrollGeneration == generation
    }
}

struct NativeVideoGridScrollResetState: Equatable {
    private(set) var requestID: UInt64 = 0
    var acknowledgedRequestID: UInt64 = 0

    mutating func request() {
        requestID &+= 1
    }
}

struct NativeVideoGridViewportAnchor: Equatable {
    let id: String
    let offsetFromViewportTop: CGFloat
}

enum NativeVideoGridAnchorRetention {
    static func targetOffsetY(
        itemOriginY: CGFloat,
        offsetFromViewportTop: CGFloat,
        minimumOffsetY: CGFloat = 0,
        maximumOffsetY: CGFloat
    ) -> CGFloat {
        min(
            max(minimumOffsetY, maximumOffsetY),
            max(minimumOffsetY, itemOriginY - offsetFromViewportTop)
        )
    }
}

struct NativeVideoScrollOffsetRetention {
    private(set) var offsetY: CGFloat
    private var persistedOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        offsetY = max(0, initialOffsetY)
        persistedOffsetY = offsetY
    }

    mutating func record(_ offsetY: CGFloat) {
        self.offsetY = max(0, offsetY)
    }

    mutating func takePendingPersistence() -> CGFloat? {
        guard abs(offsetY - persistedOffsetY) > 0.5 else { return nil }
        persistedOffsetY = offsetY
        return offsetY
    }

    mutating func markPersisted(_ offsetY: CGFloat) {
        record(offsetY)
        persistedOffsetY = self.offsetY
    }
}

struct NativeVideoScrollBindingBridge {
    private(set) var synchronizedOffsetY: CGFloat
    /// 刚被同步替换掉的旧值，binding 赶上新值后清除。
    ///
    /// SwiftUI 在同一轮更新里仍可能把它交回来，它不是新的请求。
    private var supersededOffsetY: CGFloat?

    init(initialOffsetY: CGFloat) {
        synchronizedOffsetY = max(0, initialOffsetY)
    }

    mutating func takeExternalRequest(_ offsetY: CGFloat) -> CGFloat? {
        let requestedOffsetY = max(0, offsetY)
        guard abs(requestedOffsetY - synchronizedOffsetY) > 0.5 else {
            supersededOffsetY = nil
            return nil
        }
        if let supersededOffsetY, abs(requestedOffsetY - supersededOffsetY) <= 0.5 {
            return nil
        }
        supersededOffsetY = nil
        synchronizedOffsetY = requestedOffsetY
        return requestedOffsetY
    }

    mutating func markSynchronized(_ offsetY: CGFloat) {
        let offsetY = max(0, offsetY)
        if abs(offsetY - synchronizedOffsetY) > 0.5 {
            supersededOffsetY = synchronizedOffsetY
        }
        synchronizedOffsetY = offsetY
    }
}

struct NativeVideoGridOperationEpoch {
    private(set) var value: UInt64 = 0

    mutating func advance() -> UInt64 {
        value &+= 1
        return value
    }

    func accepts(_ candidate: UInt64) -> Bool {
        candidate == value
    }
}

/// 网格几何来自 BiliUI，与加载骨架共用；预备区域与近尾部判断只属于原生网格。
typealias NativeVideoGridGeometry = VideoCardGridGeometry

extension VideoCardGridGeometry {
    /// 视野上下各多准备的高度（视野高度的倍数）：卡片提前创建，封面在滚到之前就开始加载。
    static let preparedViewportMultiple: CGFloat = 1
    /// 已准备区域在视野某一侧的余量少于这个倍数的视野高度时刷新（已到内容边缘的一侧除外）。
    static let preparedRefreshViewportMultiple: CGFloat = 0.5
    /// 视野底边离内容底部不足这么多个视野高度时请求下一页，下一页的卡片与封面在滚到之前就绪。
    static let nearEndViewportMultiple: CGFloat = 1.5

    /// 视野上下各一屏，夹在内容范围内；不并入系统建议，避免准备区域随滚动越积越大。
    static func preparedContentRect(visible: NSRect, bounds: NSRect) -> NSRect {
        let margin = visible.height * preparedViewportMultiple
        return visible.insetBy(dx: 0, dy: -margin).intersection(bounds)
    }

    /// AppKit 只在视野超出已准备区域时才再次准备；余量不足时由网格主动刷新，保持提前量。
    static func needsPreparedContentRefresh(
        prepared: NSRect,
        visible: NSRect,
        bounds: NSRect
    ) -> Bool {
        let target = preparedContentRect(visible: visible, bounds: bounds)
        guard !target.isEmpty else { return false }
        guard !prepared.isEmpty else { return true }
        let slack = visible.height * preparedRefreshViewportMultiple
        let isShortBelow = prepared.maxY < min(target.maxY, visible.maxY + slack)
        let isShortAbove = prepared.minY > max(target.minY, visible.minY - slack)
        return isShortBelow || isShortAbove
    }

    static func isNearEnd(
        itemCount: Int,
        width: CGFloat,
        visibleMaximumY: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        guard
            itemCount > 0,
            isRenderableViewport(width: width),
            visibleMaximumY.isFinite,
            viewportHeight.isFinite,
            viewportHeight > 0
        else { return false }
        let remaining = contentHeight(for: width, itemCount: itemCount) - visibleMaximumY
        return remaining < viewportHeight * nearEndViewportMultiple
    }
}
