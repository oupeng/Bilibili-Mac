import AppKit
import BiliVideoDetailFeature
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BiliKit

/// 窗口图片管线的边界：只请求公开 HTTPS 地址，响应、解码尺寸与缓存都有上界，各用途缓存互不覆盖，动图只在
/// 评论图片且不超限时保留，关闭后不再接受请求。
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
        let smallKey = try Self.key("small.png", variant: .commentPicturePreview)
        let largeKey = try Self.key("large.png", variant: .commentPicturePreview)
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

    @Test
    func imagePipelineBoundsResponseAndDecodedCache() throws {
        let megabyte = 1_024 * 1_024
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(-1, maximumBytes: 8))
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(8, maximumBytes: 8))
        #expect(!NativeVideoImagePipeline.acceptsExpectedLength(9, maximumBytes: 8))
        // 只有评论图片预览请求原图（B 站上传上限 20 MB），其余用途保持 8 MiB。
        #expect(NativeVideoImageVariant.commentPicturePreview.maximumResponseBytes == 20 * megabyte)
        for variant in [
            NativeVideoImageVariant.cover, .avatar, .commentEmote, .commentPicture,
            .trendingSearchIcon
        ] {
            #expect(variant.maximumResponseBytes == 8 * megabyte)
        }

        var countBoundCache = NativeVideoImageCache(limits: .init(countLimit: 2, costLimit: 1_024))
        let image = try #require(Self.makeImage(width: 4, height: 4))
        try countBoundCache.insert(image, animation: nil, for: Self.key("1"))
        try countBoundCache.insert(image, animation: nil, for: Self.key("2"))
        try countBoundCache.insert(image, animation: nil, for: Self.key("3"))
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        // 总上限恰好放下 4 张、单项上限恰好放下 1 张：第 5 张入缓存后按成本淘汰最久未用的那张。
        let imageCost = image.bytesPerRow * image.height
        var costBoundCache = NativeVideoImageCache(
            limits: .init(countLimit: 10, costLimit: imageCost * 4)
        )
        for name in ["a", "b", "c", "d", "e"] {
            try costBoundCache.insert(image, animation: nil, for: Self.key(name))
        }
        #expect(costBoundCache.totalCost == imageCost * 4)
        #expect(costBoundCache.count == 4)
        #expect(try costBoundCache.image(for: Self.key("a")) == nil)
        #expect(try costBoundCache.image(for: Self.key("b")) != nil)
    }

    @Test
    func imageVariantsUseDistinctCacheIdentities() throws {
        let url = try #require(URL(string: "https://i.example/shared.webp"))
        let coverKey = NativeVideoImageKey(url: url, variant: .cover)
        let avatarKey = NativeVideoImageKey(url: url, variant: .avatar)
        let commentPictureKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicture
        )
        let commentPreviewKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicturePreview
        )
        #expect(commentPictureKey != commentPreviewKey)
        let cover = try #require(Self.makeImage(width: 8, height: 4))
        let avatar = try #require(Self.makeImage(width: 4, height: 4))
        var cache = NativeVideoImageCache(limits: .init(countLimit: 2, costLimit: 1_024))

        cache.insert(cover, animation: nil, for: coverKey)
        cache.insert(avatar, animation: nil, for: avatarKey)

        #expect(cache.count == 2)
        #expect(cache.image(for: coverKey)?.width == 8)
        #expect(cache.image(for: avatarKey)?.width == 4)
    }

    @Test
    func imageVariantsEnforceDecodedPixelBounds() throws {
        let source = try #require(Self.makeImage(width: 1_000, height: 1_000))
        let data = try #require(
            NSBitmapImageRep(cgImage: source).representation(
                using: .png,
                properties: [:]
            )
        )
        let cover = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .cover)
        )
        let avatar = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .avatar)
        )

        #expect(max(cover.width, cover.height) == 640)
        #expect(max(avatar.width, avatar.height) == 96)
    }

    @Test
    func imagePipelineShutdownRejectsFutureRequestsBeforeTouchingSession() async {
        let pipeline = NativeVideoImagePipeline(cacheLimits: .window)
        pipeline.shutdown()

        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-shutdown.webp")!,
            variant: .cover
        )

        #expect(result == nil)
    }

    @Test
    func imageSessionGateSerializesRegistrationAndInvalidation() {
        let gate = NativeVideoImageSessionGate()
        let session = URLSession(configuration: .ephemeral)
        var registrationCount = 0

        #expect(gate.register { registrationCount += 1 })
        gate.invalidate(session)
        #expect(!gate.register { registrationCount += 1 })
        #expect(registrationCount == 1)
    }

    @Test
    func releasingImageOwnerSynchronouslyInvalidatesRetainedPipeline() async {
        var owner: NativeVideoImagePipelineOwner? = NativeVideoImagePipelineOwner(
            cacheLimits: .window
        )
        weak let weakOwner = owner
        let pipeline = owner!.pipeline

        owner = nil
        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-owner-release.webp")!,
            variant: .cover
        )

        #expect(weakOwner == nil)
        #expect(result == nil)
    }

    @Test
    func imageResponseAccumulatorRejectsChunkBeforeExceedingBound() {
        var accumulator = NativeVideoImageResponseAccumulator(maximumBytes: 8)

        let acceptedFirst = accumulator.append(Data(repeating: 1, count: 6))
        let rejectedOverflow = accumulator.append(Data(repeating: 2, count: 3))
        #expect(accumulator.data.count == 6)
        let acceptedBoundary = accumulator.append(Data(repeating: 3, count: 2))

        #expect(acceptedFirst)
        #expect(!rejectedOverflow)
        #expect(acceptedBoundary)
        #expect(accumulator.data.count == 8)
    }

    /// 只写出 ImageIO 能识别的位图：SVG、HTML 与随机字节都拒绝。
    @Test
    func onlyBitmapImagesAreSaved() throws {
        let pixel = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
            )
        )

        #expect(NativeVideoImagePipeline.isBitmapImage(pixel))
        #expect(
            !NativeVideoImagePipeline.isBitmapImage(
                Data(#"<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>"#.utf8)
            )
        )
        #expect(!NativeVideoImagePipeline.isBitmapImage(Data("<html></html>".utf8)))
        #expect(!NativeVideoImagePipeline.isBitmapImage(Data([0, 1, 2, 3])))
    }

    /// 取原图数据只走 HTTPS、不带用户信息；管线关闭后不再发请求。
    @Test
    func originalDataRejectsUnsafeAddressesAndClosedPipelines() async throws {
        let pipeline = NativeVideoImagePipeline(cacheLimits: .window)
        let insecure = try #require(URL(string: "http://i0.hdslb.com/bfs/a.png"))
        let withUser = try #require(URL(string: "https://user@i0.hdslb.com/bfs/a.png"))

        #expect(await pipeline.originalData(for: insecure, variant: .commentPicturePreview) == nil)
        #expect(await pipeline.originalData(for: withUser, variant: .commentPicturePreview) == nil)
        pipeline.shutdown()
        let afterShutdown = try #require(URL(string: "https://i0.hdslb.com/bfs/a.png"))
        #expect(
            await pipeline.originalData(for: afterShutdown, variant: .commentPicturePreview) == nil
        )
    }

    private static func key(
        _ name: String,
        variant: NativeVideoImageVariant = .cover
    ) throws -> NativeVideoImageKey {
        let url = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/\(name)"))
        return NativeVideoImageKey(url: url, variant: variant)
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

    private static func makeImage(width: Int = 2, height: Int = 2) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }
}
