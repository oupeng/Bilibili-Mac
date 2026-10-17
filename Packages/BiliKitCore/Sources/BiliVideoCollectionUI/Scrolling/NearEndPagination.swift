/// 自动分页的尾部状态；`tailIdentity` 标识当前最后一页，变化即视为新尾部。
package struct NearEndTailState<Identity: Equatable>: Equatable {
    package let canLoadMore: Bool
    package let tailIdentity: Identity?
    package let isLoading: Bool

    package init(canLoadMore: Bool, tailIdentity: Identity?, isLoading: Bool) {
        self.canLoadMore = canLoadMore
        self.tailIdentity = tailIdentity
        self.isLoading = isLoading
    }

    package static var end: Self {
        Self(canLoadMore: false, tailIdentity: nil, isLoading: false)
    }
}

extension NearEndTailState: Sendable where Identity: Sendable {}

/// 网格与评论侧栏共用的近尾部自动分页。
///
/// 进入阈值时每个尾部只触发一次，加载中不触发；新尾部到来时视野仍在阈值内的处理由
/// `TailChangeInsideThreshold` 决定。一次实时滚动手势最多自动加载一页。由网格 Coordinator 与侧栏控制器
/// 各自持有，只回答“现在是否该请求下一页”，请求本身由调用方发出。
package struct NearEndPagination<Identity: Equatable> {
    /// 新尾部到来时视野仍在阈值内的处理。
    package enum TailChangeInsideThreshold: Sendable {
        /// 先离开阈值再为新尾部布防：阈值比一页矮的调用方（评论侧栏）用它避免短页接连触发。
        case requiresExit
        /// 立即布防：网格的阈值是 1.5 屏，可能比一页还高，否则到底后不再翻页；仍受每尾部一次、
        /// 加载中不触发与一次手势一页约束，效果是保持阈值内有内容储备。
        case rearms
    }

    private let tailChangeInsideThreshold: TailChangeInsideThreshold
    private var tailIdentity: Identity?
    /// 上一次评估时的有效在阈值内状态（背压期间记为 false）：一直留在阈值内不重复触发；换尾部时按
    /// `TailChangeInsideThreshold` 处理。
    private var wasInsideThreshold = false
    /// 已为其触发过的尾部；同一尾部不再触发。
    private var triggeredTailIdentity: Identity?
    /// 实时滚动中触发过一次后为 true，直到新手势开始或内容整体替换时 `releaseBackpressure()`。
    private var requiresNewGesture = false

    package init(tailChangeInsideThreshold: TailChangeInsideThreshold) {
        self.tailChangeInsideThreshold = tailChangeInsideThreshold
    }

    /// 新的实时滚动手势开始或内容整体替换时解除背压。
    package mutating func releaseBackpressure() {
        requiresNewGesture = false
    }

    /// 返回 true 表示调用方应立即请求下一页。
    package mutating func shouldLoadMore(
        isInsideThreshold: Bool,
        state: NearEndTailState<Identity>,
        isLiveScrolling: Bool
    ) -> Bool {
        guard
            updateGate(
                isInsideThreshold: isInsideThreshold && !requiresNewGesture,
                state: state
            )
        else { return false }
        if isLiveScrolling { requiresNewGesture = true }
        return true
    }

    package mutating func reset() {
        tailIdentity = nil
        wasInsideThreshold = false
        triggeredTailIdentity = nil
        requiresNewGesture = false
    }

    private mutating func updateGate(
        isInsideThreshold: Bool,
        state: NearEndTailState<Identity>
    ) -> Bool {
        if state.tailIdentity != tailIdentity {
            let changedWhileStillInside =
                tailIdentity != nil && state.tailIdentity != nil
                && wasInsideThreshold && isInsideThreshold
            tailIdentity = state.tailIdentity
            triggeredTailIdentity = nil
            if changedWhileStillInside, tailChangeInsideThreshold == .requiresExit {
                wasInsideThreshold = true
                return false
            }
            wasInsideThreshold = false
        }
        guard state.canLoadMore, state.tailIdentity != nil else {
            wasInsideThreshold = false
            return false
        }
        defer { wasInsideThreshold = isInsideThreshold }
        guard isInsideThreshold,
            !wasInsideThreshold,
            !state.isLoading,
            triggeredTailIdentity != state.tailIdentity
        else { return false }
        triggeredTailIdentity = state.tailIdentity
        return true
    }
}

extension NearEndPagination: Sendable where Identity: Sendable {}
