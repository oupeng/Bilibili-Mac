import BiliModels
import Foundation

/// 布局前按弹幕模式可见性与权重筛掉事件的值类型；模式开关来自用户偏好，由弹幕会话写入。
public struct DanmakuFilter: Sendable, Equatable {
    public var showsScrolling: Bool
    public var showsTop: Bool
    public var showsBottom: Bool

    public init(
        showsScrolling: Bool = true,
        showsTop: Bool = true,
        showsBottom: Bool = true
    ) {
        self.showsScrolling = showsScrolling
        self.showsTop = showsTop
        self.showsBottom = showsBottom
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
