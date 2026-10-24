import Foundation
import Testing

@testable import BiliModels

/// BVID 只接受 `BV` 加 1–22 位 ASCII 字母数字；视频网页地址只为合法 BVID 拼出 `https://www.bilibili.com/video/<BVID>`。
struct BVIDTests {
    @Test(arguments: ["BV1xx411c7mD", "BV1", "BV" + String(repeating: "a", count: 22)])
    func validBVIDMapsToTheCanonicalVideoPage(bvid: String) {
        #expect(BVID.isValid(bvid))
        #expect(BVID.webPageURL(bvid)?.absoluteString == "https://www.bilibili.com/video/\(bvid)")
    }

    @Test(arguments: [
        "", "BV", "bv1xx411c7mD", "av170001", "BV1-stable", "BV1/../x", "BV1?p=2", "BV1#t", "BV1é",
        "BV" + String(repeating: "a", count: 23)
    ])
    func invalidBVIDHasNoVideoPage(bvid: String) {
        #expect(!BVID.isValid(bvid))
        #expect(BVID.webPageURL(bvid) == nil)
    }
}
