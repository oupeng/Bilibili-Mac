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

    /// 封面右下角的时长角标。
    static let durationBadgeTrailingInset: CGFloat = 8
    static let durationBadgeBottomInset: CGFloat = 5
    static let durationBadgePadding = CGSize(width: 4, height: 1)
    static let badgeCornerRadius: CGFloat = 3
    static let collaborationBorderWidth: CGFloat = 1
    /// “正在播放”图标与文字、各标记之间、标记与数据行之间的间距。
    static let playingIconSpacing: CGFloat = 3
    static let badgeSpacing: CGFloat = 6
    static let badgeToMetadataSpacing: CGFloat = 4

    /// 页码条显示时列表底部留出的高度，让最后一行不被悬浮的页码条挡住。
    static let pagerReservedHeight: CGFloat = 60
    static let pagerItemSize: CGFloat = 22
    static let pagerItemSpacing: CGFloat = 2
    static let pagerNumberPadding: CGFloat = 3
    static let pagerGapWidth: CGFloat = 16
    static let pagerFieldWidth: CGFloat = 40
    static let pagerHorizontalPadding: CGFloat = 12
    static let pagerVerticalPadding: CGFloat = 8
    static let pagerCollapsedLabelPadding: CGFloat = 6
    static let pagerBottomInset: CGFloat = 10
    /// 展开时页码从这个比例放大到原尺寸。
    static let pagerExpansionScale: CGFloat = 0.6
    static let pagerExpansionDuration: Double = 0.28

    /// 空间层滑入／滑出侧栏的动画时长。
    static let layerTransitionDuration: Double = 0.28

    /// 头部下方状态提示（空、失败、登录）的间距与左右留白。
    static let messageSpacing: CGFloat = 12
    static let messageHorizontalPadding: CGFloat = 24

    /// 加载、空、失败等状态覆盖层从头部下方开始，返回按钮始终可点。
    static let stateContentTop: CGFloat = listTopInset + headerHeight + headerBottomSpacing
}
