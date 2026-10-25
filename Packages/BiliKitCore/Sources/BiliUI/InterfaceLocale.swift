import Foundation

/// 格式化用的 locale：语言与字符串目录实际选中的界面语言一致，地区与用户的格式偏好沿用 `Locale.current`。
///
/// 系统语言列表里没有 App 支持的语言时（例如只有法语或德语），字符串目录回退到开发语言 zh-Hans，`Locale.current`
/// 的语言却由 Foundation 另行协商成 en（en_FR）；直接用它格式化会在中文文案里混进「12.3K」「Yesterday」。计数、日期、
/// 相对时间、时长与百分比都经这里取 locale，与文案同一种语言；地区仍按用户设置，小数点、日月顺序随地区。
///
/// 只拥有 locale 的推导，不拥有任何格式。语言取 BiliUI 资源 bundle 的协商结果：各 target 与 App 的目录提供同样四种
/// 语言、同一开发语言，协商结果与 `Bundle.main` 一致。测试进程的 `Bundle.main` 是测试 runner，协商结果随进程语言，
/// 所以格式化函数都保留显式 `locale` 参数，测试传固定 locale。
///
/// 不注入 SwiftUI 环境 `locale`：工程契约禁止在根上强制界面 locale（`check-project-contract.sh`，它同时决定排版语言与
/// 字形）。环境 `locale` 因此仍是系统 locale，视图不把它传给格式化，取格式化函数的默认参数。
public enum InterfaceLocale {
    /// 每次读取都重新推导：地区与格式偏好在运行中可能被用户改掉，界面语言只在重启后变化。
    public static var current: Locale {
        let systemLocale = Locale.current
        guard let identifier = BiliUIStrings.bundle.preferredLocalizations.first else {
            return systemLocale
        }
        let interfaceLanguage = Locale.Language(identifier: identifier)
        // 语言一致时原样返回：`Locale.current` 还带着 24 小时制、自定义日期格式等系统偏好，重新构造只保留得下
        // `Locale.Components` 能表达的那部分。
        if systemLocale.language.languageCode == interfaceLanguage.languageCode,
            systemLocale.language.script == interfaceLanguage.script
        {
            return systemLocale
        }
        // 地区在 `languageComponents.region` 里（`Components.region` 是地区覆盖），换语言时要带上原来的地区。
        var components = Locale.Components(locale: systemLocale)
        components.languageComponents = Locale.Language.Components(
            languageCode: interfaceLanguage.languageCode,
            script: interfaceLanguage.script,
            region: systemLocale.region
        )
        return Locale(components: components)
    }
}
