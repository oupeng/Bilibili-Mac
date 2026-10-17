import Foundation

/// 顶部刷新胶囊（`RefreshStatusCapsule`）与底部分页胶囊（`PaginationStatusOverlay`）的唯一几何来源。
package enum StatusCapsuleGeometry {
    package static let contentPadding: CGFloat = 8
    package static let spacing: CGFloat = 8
    /// 胶囊与列表边缘的距离：窄窗口下两行说明也不贴边。
    package static let horizontalInset: CGFloat = 24
    package static let bottomInset: CGFloat = 8
    package static let messageLineLimit = 2
}
