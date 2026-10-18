import BiliNetworking
import Foundation
import Testing

/// 接口给的图片地址（BiliAPI 的封面、头像与评论图片，BiliAuth 的账号头像）只升级为 HTTPS 并过公开 HTTPS
/// 基线，越界时整张图丢弃。
struct WebImageURLTests {
    @Test(arguments: [
        "//i0.hdslb.com/bfs/archive/fixture.jpg",
        "http://i0.hdslb.com/bfs/archive/fixture.jpg",
        "https://i0.hdslb.com/bfs/archive/fixture.jpg"
    ])
    func upgradesPublicImageAddressesToHTTPS(value: String) {
        #expect(
            WebImageURL.parse(value)?.absoluteString
                == "https://i0.hdslb.com/bfs/archive/fixture.jpg"
        )
    }

    @Test(arguments: [
        "https://192.168.1.1/cover.jpg",
        "https://127.0.0.1/avatar.png",
        "https://[::1]/cover.jpg",
        "https://localhost/cover.jpg",
        "https://printer.local/cover.jpg",
        "https://i0.hdslb.com:8443/bfs/archive/fixture.jpg",
        "https://user@i0.hdslb.com/bfs/archive/fixture.jpg",
        "ftp://i0.hdslb.com/bfs/archive/fixture.jpg",
        "javascript:fixture",
        ""
    ])
    func rejectsAddressesOutsideThePublicHTTPSBaseline(value: String) {
        #expect(WebImageURL.parse(value) == nil)
    }
}
