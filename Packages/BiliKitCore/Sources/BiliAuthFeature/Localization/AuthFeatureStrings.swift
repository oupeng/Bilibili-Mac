import Foundation

/// BiliAuthFeature 的字符串目录入口：本 target 的文案只从自己的 `Localizable.xcstrings` 查。
enum AuthFeatureStrings {
    static let bundle = Bundle.module

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
