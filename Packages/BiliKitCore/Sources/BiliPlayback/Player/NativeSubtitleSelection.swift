@preconcurrency import AVFoundation
import Foundation

/// 用户上次选中的原生字幕选项（系统属性列表的二进制编码），重新开启字幕时优先恢复同一选项。
struct NativeSubtitleSelectionPreference: Sendable {
    let propertyListData: Data?
}

extension AVPlayerEngine {
    static func subtitlePreference(
        for option: AVMediaSelectionOption
    ) -> NativeSubtitleSelectionPreference {
        NativeSubtitleSelectionPreference(
            propertyListData: try? PropertyListSerialization.data(
                fromPropertyList: option.propertyList(),
                format: .binary,
                options: 0
            )
        )
    }

    /// 开启字幕时选哪一项：能恢复上次的选项就恢复，否则按系统偏好语言排序取第一项。
    ///
    /// 系统可能在字幕菜单里插入不在 BiliKit 目录里的翻译轨（例如有英文字幕时翻成界面语言），按系统排序取
    /// 字幕时可能选中它；没有公开 API 可以排除它。
    static func subtitleOption(
        in group: AVMediaSelectionGroup,
        restoring preference: NativeSubtitleSelectionPreference?
    ) -> AVMediaSelectionOption? {
        let playable = AVMediaSelectionGroup.playableMediaSelectionOptions(
            from: group.options
        )
        guard !playable.isEmpty else { return nil }
        if let preference {
            if let data = preference.propertyListData,
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ),
                let exact = group.mediaSelectionOption(
                    withPropertyList: propertyList
                ),
                exact.isPlayable
            {
                return exact
            }
        }
        let preferred = AVMediaSelectionGroup.mediaSelectionOptions(
            from: playable,
            filteredAndSortedAccordingToPreferredLanguages:
                Locale.preferredLanguages
        )
        return preferred.first ?? playable.first
    }
}
