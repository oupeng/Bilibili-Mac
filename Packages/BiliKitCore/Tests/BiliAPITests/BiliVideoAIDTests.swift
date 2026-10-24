import Testing

@testable import BiliAPI

/// av 号与 BV 号的本地换算互逆：评论链接按 av 号播放、账户写入按卡片的 BV 号传 aid，两边用同一套规则。
@Suite("BV and av conversion")
struct BiliVideoAIDTests {
    static let knownPairs: [(Int64, String)] = [
        (2, "BV1xx411c7mD"),
        (170001, "BV17x411w7KC"),
        (111_298_867_365_120, "BV1L9Uoa9EUx")
    ]

    @Test(arguments: knownPairs)
    func convertsKnownPairsBothWays(aid: Int64, bvid: String) {
        #expect(BiliVideoAID.bvid(fromAID: aid) == bvid)
        #expect(BiliVideoAID.aid(fromBVID: bvid) == aid)
    }

    @Test(arguments: [1, 99, 1_000_003, 1 << 40, (1 << 51) - 1] as [Int64])
    func roundTripsAcrossTheRange(_ aid: Int64) throws {
        let bvid = try #require(BiliVideoAID.bvid(fromAID: aid))
        #expect(BiliVideoAID.aid(fromBVID: bvid) == aid)
    }

    @Test(arguments: [Int64(0), -1, 1 << 51, .max])
    func rejectsAIDsOutsideTheConversionRange(_ aid: Int64) {
        #expect(BiliVideoAID.bvid(fromAID: aid) == nil)
    }

    /// 长度、前缀、大小写或字符不属于这套编码的 BV 号不换算，不会被当成某个 aid 发进写请求。
    @Test(
        arguments: [
            "", "BV1xx411c7m", "BV1xx411c7mDx", "bv1xx411c7mD", "BV2xx411c7mD",
            "BV1xx411c7m0", "BV1xx411c7mI"
        ]
    )
    func rejectsBVIDsOutsideTheEncoding(_ bvid: String) {
        #expect(BiliVideoAID.aid(fromBVID: bvid) == nil)
    }
}
