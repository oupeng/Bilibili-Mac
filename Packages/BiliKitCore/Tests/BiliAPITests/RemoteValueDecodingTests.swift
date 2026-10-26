import Foundation
import Testing

@testable import BiliAPI

/// 接口取值形状不固定时的解码：计数非数字按缺失，标识接受字符串或整数，UP 主 MID 必须能解析为整数。
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

    private struct Identifier: Decodable {
        let id: String

        private enum CodingKeys: String, CodingKey {
            case id
        }

        init(from decoder: any Decoder) throws {
            id = try decoder.container(keyedBy: CodingKeys.self).decodeIntegerText(forKey: .id)
        }
    }

    @Test(
        arguments: [
            (#"{"id":"0123"}"#, "0123"),
            (#"{"id":"abc"}"#, "abc"),
            (#"{"id":9007199254740993}"#, "9007199254740993"),
            (#"{"id":-5}"#, "-5"),
            (#"{"id":true}"#, nil),
            (#"{"id":1.5}"#, nil),
            (#"{"id":null}"#, nil),
            ("{}", nil)
        ] as [(String, String?)]
    )
    func integerTextAcceptsStringOrIntegerShapes(json: String, expected: String?) {
        let decoded = try? JSONDecoder().decode(Identifier.self, from: Data(json.utf8))
        #expect(decoded?.id == expected)
    }

    @Test(
        arguments: [
            (#"{"mid":42,"sign":""}"#, Int64(42)),
            (#"{"mid":"42","sign":""}"#, 42),
            (#"{"mid":"4x2","sign":""}"#, nil),
            (#"{"mid":true,"sign":""}"#, nil)
        ] as [(String, Int64?)]
    )
    func uploaderMIDAcceptsIntegerOrNumericString(json: String, expected: Int64?) {
        let decoded = try? JSONDecoder().decode(UploaderCardPayload.self, from: Data(json.utf8))
        #expect(decoded?.mid == expected)
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
