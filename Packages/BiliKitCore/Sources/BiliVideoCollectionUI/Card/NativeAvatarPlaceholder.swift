import AppKit

/// 头像缺省、加载中或加载失败时的占位剪影；所有头像位置共用。
package enum NativeAvatarPlaceholder {
    package static let systemSymbolName = "person.crop.circle.fill"
    package static var tintColor: NSColor { .quaternaryLabelColor }
}
