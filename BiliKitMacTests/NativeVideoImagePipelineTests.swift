import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct NativeVideoImagePipelineTests {
    @Test(arguments: [
        ("https://i0.hdslb.com/bfs/archive/fixture.jpg", true),
        ("https://album.biliimg.com/bfs/new_dyn/fixture.jpg", true),
        ("http://i0.hdslb.com/bfs/archive/fixture.jpg", false),
        ("https://127.0.0.1/cover.jpg", false),
        ("https://localhost/cover.jpg", false),
        ("https://i0.hdslb.com:8443/bfs/archive/fixture.jpg", false),
        ("https://user@i0.hdslb.com/bfs/archive/fixture.jpg", false)
    ])
    func requestsOnlyPublicHTTPSImageAddresses(urlString: String, accepted: Bool) throws {
        let url = try #require(URL(string: urlString))
        #expect(NativeVideoImagePipeline.acceptsRequestURL(url) == accepted)
    }

    @Test
    func waiterDeliversTheFirstResultWhetherItFinishesBeforeOrAfterSuspension() async throws {
        let image = try #require(Self.makeImage())
        let result = NativeVideoImageLoadResult(image: image, origin: .network, animation: nil)

        let finishedFirst = NativeVideoImageWaiter()
        finishedFirst.finish(with: result)
        finishedFirst.finish(with: nil)
        #expect(await finishedFirst.value()?.image === image)

        let suspendedFirst = NativeVideoImageWaiter()
        async let value = suspendedFirst.value()
        // 两次 finish 都可能先于挂起到达；无论哪种顺序都只 resume 一次且保留第一个结果。
        suspendedFirst.finish(with: nil)
        suspendedFirst.finish(with: result)
        #expect(await value == nil)
    }

    /// 只有评论图片的列表格子与预览保留动图数据；帧数与第一帧尺寸都要在播放门槛内。
    @Test
    func animationIsRetainedOnlyForCommentPicturesWithinThePolicy() throws {
        let animated = try #require(Self.makeGIF(frameCount: 3, width: 4, height: 4))
        let still = try #require(Self.makeGIF(frameCount: 1, width: 4, height: 4))

        let retained = NativeVideoImagePipeline.decodeAnimation(animated, variant: .commentPicture)
        #expect(retained?.data == animated)
        #expect(
            NativeVideoImagePipeline.decodeAnimation(animated, variant: .commentPicturePreview)
                != nil
        )
        for variant in [
            NativeVideoImageVariant.cover, .avatar, .commentEmote, .trendingSearchIcon
        ] {
            #expect(NativeVideoImagePipeline.decodeAnimation(animated, variant: variant) == nil)
        }
        #expect(NativeVideoImagePipeline.decodeAnimation(still, variant: .commentPicture) == nil)
        // 第一帧仍按原规则解码，动图与静态图共用同一个首帧路径。
        #expect(NativeVideoImagePipeline.decodeImage(animated, variant: .commentPicture) != nil)
    }

    @Test
    func animationsBeyondTheFrameOrPixelCapShowOnlyTheFirstFrame() throws {
        let tooManyFrames = try #require(
            Self.makeGIF(
                frameCount: NativeAnimatedImagePolicy.maximumFrameCount + 1,
                width: 1,
                height: 1
            )
        )
        let side = Int(Double(NativeAnimatedImagePolicy.maximumPixelCount).squareRoot()) + 1
        let tooLarge = try #require(Self.makeGIF(frameCount: 2, width: side, height: side))

        #expect(
            NativeVideoImagePipeline.decodeAnimation(tooManyFrames, variant: .commentPicture) == nil
        )
        #expect(
            NativeVideoImagePipeline.decodeAnimation(tooLarge, variant: .commentPicturePreview)
                == nil
        )
    }

    /// 缓存成本包括动图编码数据；缓存命中时动图数据随第一帧一起返回。
    @Test
    func cacheCostIncludesRetainedAnimationData() throws {
        let image = try #require(Self.makeImage())
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/a.gif"))
        let key = NativeVideoImageKey(url: url, variant: .commentPicture)
        let animation = NativeAnimatedImage(data: Data(count: 100))
        var cache = NativeVideoImageCache(limits: .init(countLimit: 4, costLimit: 1_024))

        cache.insert(image, animation: animation, for: key)

        #expect(cache.totalCost == image.bytesPerRow * image.height + 100)
        #expect(cache.animation(for: key) === animation)
    }

    /// 单项超过总成本上限的份额时不缓存，也不挤掉已缓存的图片。
    @Test
    func oversizedEntryNeitherCachesNorEvictsOthers() throws {
        let small = try #require(Self.makeImage())
        let smallCost = small.bytesPerRow * small.height
        let limits = NativeVideoImageCacheLimits(countLimit: 4, costLimit: smallCost * 8)
        var cache = NativeVideoImageCache(limits: limits)
        let smallKey = try Self.key("small.png")
        let largeKey = try Self.key("large.png")
        cache.insert(small, animation: nil, for: smallKey)

        let oversizedAnimation = NativeAnimatedImage(
            data: Data(count: limits.maximumEntryCost)
        )
        cache.insert(small, animation: oversizedAnimation, for: largeKey)

        #expect(cache.image(for: largeKey) == nil)
        #expect(cache.image(for: smallKey) != nil)
        #expect(cache.totalCost == smallCost)
    }

    /// Now Playing 只要一张封面：上界远小于窗口，但仍放得下解码上限内最大的封面。
    @Test
    func nowPlayingArtworkCacheIsSmallButHoldsTheLargestCover() {
        let artwork = NativeVideoImageCacheLimits.nowPlayingArtwork
        let window = NativeVideoImageCacheLimits.window
        let edge = NativeVideoImageVariant.cover.maximumDecodedPixelSize
        let largestCoverCost = edge * edge * 4

        #expect(artwork.countLimit < window.countLimit)
        #expect(artwork.costLimit < window.costLimit)
        #expect(largestCoverCost <= artwork.maximumEntryCost)
    }

    private static func key(_ name: String) throws -> NativeVideoImageKey {
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/\(name)"))
        return NativeVideoImageKey(url: url, variant: .commentPicturePreview)
    }

    private static func makeGIF(frameCount: Int, width: Int, height: Int) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.gif.identifier as CFString,
                frameCount,
                nil
            )
        else { return nil }
        for index in 0..<frameCount {
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.setFillColor(gray: CGFloat(index % 2), alpha: 1)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let frame = context?.makeImage() else { return nil }
            CGImageDestinationAddImage(
                destination,
                frame,
                [
                    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]
                ] as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func makeImage() -> CGImage? {
        let context = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
