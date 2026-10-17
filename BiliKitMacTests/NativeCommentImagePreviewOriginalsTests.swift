import CoreGraphics
import Testing

@testable import BiliKit
@testable import BiliVideoDetailFeature

@MainActor
struct NativeCommentImagePreviewOriginalsTests {
    /// 共享缓存放不下的大原图由预览会话持有：翻到下一张再回上一张不重复请求。
    @Test
    func returningToTheNeighborDoesNotRequestAgain() async throws {
        let originals = NativeCommentImagePreviewOriginals()
        let image = try #require(Self.makeImage())
        var requested: [Int] = []
        func load(_ index: Int) async -> VideoDetailImage? {
            await originals.image(at: index) {
                requested.append(index)
                return VideoDetailImage(image: image, animation: nil, fadesIn: true)
            }
        }

        _ = await load(0)
        _ = await load(1)
        let back = await load(0)

        #expect(requested == [0, 1])
        #expect(back?.fadesIn == false)
    }

    /// 只持有当前与前后各一张：走远之后再回来要重新请求。
    @Test
    func imagesBeyondTheNeighborsAreReleased() async throws {
        let originals = NativeCommentImagePreviewOriginals()
        let image = try #require(Self.makeImage())
        var requested: [Int] = []
        func load(_ index: Int) async {
            _ = await originals.image(at: index) {
                requested.append(index)
                return VideoDetailImage(image: image, animation: nil, fadesIn: true)
            }
        }

        await load(0)
        await load(1)
        await load(2)
        await load(0)

        #expect(requested == [0, 1, 2, 0])
    }

    private static func makeImage() -> CGImage? {
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
