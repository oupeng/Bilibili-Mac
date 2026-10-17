import Foundation

/// 播放页与 UP 主空间的文案入口：只查本 target 的字符串目录，不读 App 的 `Bundle.main`。
enum VideoDetailFeatureStrings {
    static let bundle = Bundle.module

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
