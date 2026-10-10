import Foundation
import Testing

@testable import BiliAPI

struct RemoteValueDecodingTests {
    private struct Counter: Decodable {
        let count: FlexibleInt64
    }

    @Test(
        arguments: [
            (#"{"count":12345}"#, Int64(12_345)),
            (#"{"count":"678"}"#, 678),
            (#"{"count":"--"}"#, nil),
            (#"{"count":null}"#, nil)
        ] as [(String, Int64?)]
    )
    func flexibleInt64TreatsNonNumericAsMissing(json: String, expected: Int64?) throws {
        let decoded = try JSONDecoder().decode(Counter.self, from: Data(json.utf8))
        #expect(decoded.count.value == expected)
    }

    @Test(
        arguments: [
            ("12:34", 754),
            ("1:02:03", 3_723),
            ("00:00", 0),
            ("5", nil),
            ("a:b", nil),
            (":30", nil),
            ("1::30", nil),
            ("-1:00", nil),
            ("1:2:3:4", nil)
        ] as [(String, Int?)]
    )
    func clockDurationAcceptsOnlyTwoOrThreeNonNegativeParts(value: String, expected: Int?) {
        #expect(RemoteClockDuration.seconds(value) == expected)
    }

    @Test
    func lossyDecodableKeepsValidElementsOnly() throws {
        let json = #"[{"count":1},{"count":true},{"count":"2"}]"#
        let decoded = try JSONDecoder().decode(
            [LossyDecodable<Counter>].self,
            from: Data(json.utf8)
        )
        #expect(decoded.map { $0.value?.count.value } == [1, nil, 2])
    }
}
