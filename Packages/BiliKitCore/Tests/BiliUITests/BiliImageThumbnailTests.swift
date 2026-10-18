import BiliUI
import Foundation
import Testing

/// 卡片封面与头像只对 B 站图片 CDN 的干净地址追加缩略参数，其余地址原样交给图片管线。
struct BiliImageThumbnailTests {
    @Test
    func trustedCDNImagesGetBoundedVariants() throws {
        let cover = try #require(URL(string: "https://i0.hdslb.com/bfs/archive/cover.jpg"))
        let avatar = try #require(URL(string: "https://hdslb.com/bfs/face/avatar.jpg"))

        #expect(
            BiliImageThumbnail.url(cover, size: .videoCover)?.absoluteString
                == "https://i0.hdslb.com/bfs/archive/cover.jpg@640w_360h_1c.webp"
        )
        #expect(
            BiliImageThumbnail.url(avatar, size: .avatar)?.absoluteString
                == "https://hdslb.com/bfs/face/avatar.jpg@96w_96h_1c.webp"
        )
        #expect(BiliImageThumbnail.url(nil, size: .avatar) == nil)
    }

    @Test(arguments: [
        "https://images.example/avatar.jpg",
        "https://evilhdslb.com/avatar.jpg",
        "https://i0.hdslb.com/avatar.jpg?token=public",
        "https://i0.hdslb.com/avatar.jpg#fragment",
        "https://i0.hdslb.com/avatar.jpg@48w_48h.webp"
    ])
    func unknownAmbiguousOrAlreadyTransformedURLsStayUnchanged(_ value: String) throws {
        let url = try #require(URL(string: value))

        #expect(BiliImageThumbnail.url(url, size: .videoCover) == url)
        #expect(BiliImageThumbnail.url(url, size: .avatar) == url)
    }
}
