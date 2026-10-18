import Foundation

/// BiliUI 自己的字符串目录入口：共享呈现组件的文案只从本 target 的 `Localizable.xcstrings` 查。
///
/// 调用方传入的标签与标题仍由调用方的 target 本地化；这里只负责 BiliUI 自己拥有的文案。
enum BiliUIStrings {
    static let bundle = Bundle.module

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
