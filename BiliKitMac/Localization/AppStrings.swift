import Foundation

/// App 外壳界面文字的本地化入口，从 App 主 bundle 的字符串目录取值。
///
/// SwiftUI 视图传入环境里的 `locale`；各 Feature 有自己的字符串目录，不经这里。
enum AppStrings {
    static let bundle = Bundle.main

    static func localized(
        _ value: String.LocalizationValue,
        locale: Locale = .current
    ) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
