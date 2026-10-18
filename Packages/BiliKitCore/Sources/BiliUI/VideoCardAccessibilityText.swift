import Foundation

/// 视频卡片里由 BiliUI 拥有的读屏文案；卡片的标签与帮助由调用方给出。
package enum VideoCardAccessibilityText {
    /// 卡片处于选中状态时的读屏值。
    package static var selectedValue: String { BiliUIStrings.localized("已选择") }

    /// 不能进入播放的卡片的读屏值；具体原因在调用方给出的标签里。
    package static var unavailableValue: String { BiliUIStrings.localized("不可播放") }

    /// 卡片读屏值的唯一来源：依次列出“不可播放”与“已选择”，两者都不成立时为 nil。
    package static func value(isSelected: Bool, isActivatable: Bool) -> String? {
        let parts = [
            isActivatable ? nil : unavailableValue,
            isSelected ? selectedValue : nil
        ].compactMap(\.self)
        return parts.isEmpty ? nil : ListFormatter.localizedString(byJoining: parts)
    }
}
