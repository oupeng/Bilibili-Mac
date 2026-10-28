import Foundation
import Testing

@testable import BiliModels

/// BVID 只接受 `BV` 加 1–22 位 ASCII 字母数字；视频网页地址只为合法 BVID 拼出 `https://www.bilibili.com/video/<BVID>`，
/// 带分 P 与时间时只写正整数的 `p`、`t`。
struct BVIDTests {
    @Test(arguments: ["BV1xx411c7mD", "BV1", "BV" + String(repeating: "a", count: 22)])
    func validBVIDMapsToTheCanonicalVideoPage(bvid: String) {
        #expect(BVID.isValid(bvid))
        #expect(BVID.webPageURL(bvid)?.absoluteString == "https://www.bilibili.com/video/\(bvid)")
    }

    @Test(arguments: [
        "", "BV", "bv1xx411c7mD", "av170001", "BV1-stable", "BV1/../x", "BV1?p=2", "BV1#t", "BV1é",
        "BV１２",
        "BV" + String(repeating: "a", count: 23)
    ])
    func invalidBVIDHasNoVideoPage(bvid: String) {
        #expect(!BVID.isValid(bvid))
        #expect(BVID.webPageURL(bvid) == nil)
    }

    @Test
    func pageAndStartSecondsAreWrittenOnlyWhenPositive() {
        let bvid = "BV1xx411c7mD"
        let base = "https://www.bilibili.com/video/\(bvid)"
        let both = BVID.webPageURL(bvid, pageNumber: 2, startSeconds: 95)
        let timeOnly = BVID.webPageURL(bvid, pageNumber: nil, startSeconds: 95)
        let neither = BVID.webPageURL(bvid, pageNumber: 0, startSeconds: -1)
        #expect(both?.absoluteString == base + "?p=2&t=95")
        #expect(timeOnly?.absoluteString == base + "?t=95")
        #expect(neither?.absoluteString == base)
        #expect(BVID.webPageURL("BV1?p=2", pageNumber: 2, startSeconds: 95) == nil)
    }
}
