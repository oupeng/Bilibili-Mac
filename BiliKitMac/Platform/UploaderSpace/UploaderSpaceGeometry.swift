import CoreGraphics

/// UP 主空间层的唯一几何来源：原生列表、状态覆盖层与页码条共用。
enum UploaderSpaceGeometry {
    static let listHorizontalInset: CGFloat = 8
    static let listTopInset: CGFloat = 8
    static let listBottomInset: CGFloat = 12

    static let headerHeight: CGFloat = 40
    static let headerBottomSpacing: CGFloat = 10
    static let headerHorizontalPadding: CGFloat = 8
    static let headerSpacing: CGFloat = 10
    static let backButtonSize: CGFloat = 24
    static let avatarSize: CGFloat = 28

    /// 用户在 spike 中对比 128／160／200 后选定 160。
    static let coverWidth: CGFloat = 160
    static let coverHeight: CGFloat = coverWidth * 9 / 16
    static let coverCornerRadius: CGFloat = 6
    static let coverTextSpacing: CGFloat = 10
    static let rowPadding: CGFloat = 8
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = 8
    static let rowHeight: CGFloat = coverHeight + rowPadding * 2

    /// 页码条显示时列表底部留出的高度，让最后一行不被悬浮的页码条挡住。
    static let pagerReservedHeight: CGFloat = 60
    /// 滚过这个距离后显示“返回顶部”。
    static let topButtonThreshold: CGFloat = 400

    /// 骨架、空、失败等状态覆盖层从头部下方开始，返回按钮始终可点。
    static let stateContentTop: CGFloat = listTopInset + headerHeight + headerBottomSpacing
}
