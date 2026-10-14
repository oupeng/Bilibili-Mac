import Foundation
import Testing

@testable import BiliAPI

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
        "https://[::1]/cover.jpg",
        "https://localhost/cover.jpg",
        "https://printer.local/cover.jpg",
        "https://i0.hdslb.com:8443/bfs/archive/fixture.jpg",
        "https://user@i0.hdslb.com/bfs/archive/fixture.jpg",
        "ftp://i0.hdslb.com/bfs/archive/fixture.jpg",
        ""
    ])
    func rejectsAddressesOutsideThePublicHTTPSBaseline(value: String) {
        #expect(WebImageURL.parse(value) == nil)
    }
}
