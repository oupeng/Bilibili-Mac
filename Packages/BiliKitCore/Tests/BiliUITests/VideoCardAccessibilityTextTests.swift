import Foundation
import Testing

@testable import BiliUI

/// 卡片读屏标签里的时长用带单位的完整写法，不用封面上会被读成时刻的「12:34」；单位随传入的 locale。
struct VideoCardAccessibilityTextTests {
    @Test(arguments: [
        (identifier: "zh-Hans", seconds: 754, spoken: "12分钟34秒钟"),
        (identifier: "zh-Hans", seconds: 3_600, spoken: "1小时"),
        (identifier: "ja", seconds: 3_725, spoken: "1時間 2分 5秒"),
        (identifier: "en", seconds: 754, spoken: "12 minutes, 34 seconds"),
        (identifier: "en", seconds: -5, spoken: "0 seconds")
    ])
    func spokenDurationUsesUnits(identifier: String, seconds: Int, spoken: String) {
        let text = VideoCardAccessibilityText.duration(
            seconds: seconds,
            locale: Locale(identifier: identifier)
        )

        // 「时长」前缀按进程语言查 BiliUI 的目录，期望值同样从目录取。
        #expect(text == String(localized: "时长 \(spoken)", bundle: BiliUIStrings.bundle))
    }
}
