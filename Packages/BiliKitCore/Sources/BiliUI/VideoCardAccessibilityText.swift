import Foundation

/// 视频卡片里由 BiliUI 拥有的读屏文案；卡片的标签与帮助由调用方给出。
package enum VideoCardAccessibilityText {
    /// 卡片处于选中状态时的读屏值。
    package static var selectedValue: String { BiliUIStrings.localized("已选择") }
}
