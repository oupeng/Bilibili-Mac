import Foundation

/// 弹幕画面上的文案入口（互动弹幕卡片与“UP主”标签）：只查本 target 的字符串目录，不读 App 的 `Bundle.main`。
///
/// 纹理在后台栅格化，`String(localized:)` 可在任意线程调用。
enum DanmakuStrings {
    static let bundle = Bundle.module

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
