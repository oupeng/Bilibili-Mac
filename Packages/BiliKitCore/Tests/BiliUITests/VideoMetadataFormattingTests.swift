import Foundation
import Testing

@testable import BiliUI

/// 紧凑计数按 locale 的语言给单位、最多一位小数且向下截断；地区只决定小数点。
struct VideoMetadataFormattingTests {
    @Test(arguments: [
        (
            "zh-Hans",
            ["0", "999", "1000", "9999", "1万", "1.2万", "9.9万", "9999.9万", "1亿", "1.2亿", "12.3亿"]
        ),
        (
            "zh-Hant",
            ["0", "999", "1000", "9999", "1萬", "1.2萬", "9.9萬", "9999.9萬", "1億", "1.2億", "12.3億"]
        ),
        (
            "ja",
            ["0", "999", "1000", "9999", "1万", "1.2万", "9.9万", "9999.9万", "1億", "1.2億", "12.3億"]
        ),
        (
            "en",
            ["0", "999", "1K", "9.9K", "10K", "12.3K", "99.9K", "99.9M", "100M", "123.4M", "1.2B"]
        ),
        (
            "zh-Hans_FR",
            ["0", "999", "1000", "9999", "1万", "1,2万", "9,9万", "9999,9万", "1亿", "1,2亿", "12,3亿"]
        )
    ])
    func compactCountsTruncateToOneFractionDigit(localeIdentifier: String, expected: [String]) {
        let counts: [Int64] = [
            -1, 999, 1000, 9999, 10_000, 12_345, 99_999, 99_999_999, 100_000_000, 123_456_789,
            1_234_567_890
        ]
        let locale = Locale(identifier: localeIdentifier)

        #expect(counts.map { VideoMetadataFormatting.compactCount($0, locale: locale) } == expected)
    }
}
