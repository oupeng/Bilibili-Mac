import AppKit

/// 打开时独占方向键等按键的浮层；播放器快捷键不会越过它。
///
/// 跨 target 契约：本 target 的浮层（评论图片预览的宿主视图）声明遵循；App 的
/// `PlayerKeyboardShortcutController` 沿第一响应者的父视图链检查它，命中时把按键留给浮层。
@MainActor
public protocol PlayerKeyboardFocusOwner: NSView {}
