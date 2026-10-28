import BiliModels
import Foundation

/// 布局前对事件的处理：按弹幕模式可见性与权重筛掉事件，再按偏好合并重复弹幕（`DanmakuDuplicateMerger`）。
///
/// 模式开关与合并开关来自用户偏好，由弹幕会话写入；任一项变化都整张重排。合并在这里默认关闭，只是会话收到
/// 偏好之前的初值；产品默认值是 `DanmakuDuplicateMerging.defaultIsEnabled`。
public struct DanmakuFilter: Sendable, Equatable {
    public var showsScrolling: Bool
    public var showsTop: Bool
    public var showsBottom: Bool
    public var mergesDuplicates: Bool

    public init(
        showsScrolling: Bool = true,
        showsTop: Bool = true,
        showsBottom: Bool = true,
        mergesDuplicates: Bool = false
    ) {
        self.showsScrolling = showsScrolling
        self.showsTop = showsTop
        self.showsBottom = showsBottom
        self.mergesDuplicates = mergesDuplicates
    }

    /// 权重为负的弹幕不显示；下限固定为 0，不随偏好变化。
    private static let minimumWeight = 0

    func allows(_ event: DanmakuEvent) -> Bool {
        guard event.weight >= Self.minimumWeight else { return false }
        return switch event.mode {
        case .scrolling: showsScrolling
        case .top: showsTop
        case .bottom: showsBottom
        }
    }
}
