import Foundation
import Testing

@testable import BiliUI

/// 格式化 locale 的语言是字符串目录选中的语言，地区沿用系统 locale；与运行进程的语言设置无关。
struct InterfaceLocaleTests {
    @Test
    func languageFollowsCatalogAndRegionFollowsSystem() throws {
        let catalogLanguage = Locale.Language(
            identifier: try #require(BiliUIStrings.bundle.preferredLocalizations.first)
        )
        let locale = InterfaceLocale.current

        #expect(locale.language.languageCode == catalogLanguage.languageCode)
        #expect(locale.language.script == catalogLanguage.script)
        #expect(locale.region == Locale.current.region)
    }
}
