import AppKit
import BiliBrowseFeature
import BiliModels
import BiliVideoCollectionUI
import CoreGraphics
import Foundation
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct PopularNativeGridTests {
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
        let image = try #require(makeImage(width: 4, height: 4))
        countBoundCache.insert(image, animation: nil, for: imageKey("1"))
        countBoundCache.insert(image, animation: nil, for: imageKey("2"))
        countBoundCache.insert(image, animation: nil, for: imageKey("3"))
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        // 总上限恰好放下 4 张、单项上限恰好放下 1 张：第 5 张入缓存后按成本淘汰最久未用的那张。
        let imageCost = image.bytesPerRow * image.height
        var costBoundCache = NativeVideoImageCache(
            limits: .init(countLimit: 10, costLimit: imageCost * 4)
        )
        for name in ["a", "b", "c", "d", "e"] {
            costBoundCache.insert(image, animation: nil, for: imageKey(name))
        }
        #expect(costBoundCache.totalCost == imageCost * 4)
        #expect(costBoundCache.count == 4)
        #expect(costBoundCache.image(for: imageKey("a")) == nil)
        #expect(costBoundCache.image(for: imageKey("b")) != nil)
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
        let cover = try #require(makeImage(width: 8, height: 4))
        let avatar = try #require(makeImage(width: 4, height: 4))
        var cache = NativeVideoImageCache(limits: .init(countLimit: 2, costLimit: 1_024))

        cache.insert(cover, animation: nil, for: coverKey)
        cache.insert(avatar, animation: nil, for: avatarKey)

        #expect(cache.count == 2)
        #expect(cache.image(for: coverKey)?.width == 8)
        #expect(cache.image(for: avatarKey)?.width == 4)
    }

    @Test
    func imageVariantsEnforceDecodedPixelBounds() throws {
        let source = try #require(makeImage(width: 1_000, height: 1_000))
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

    @Test @MainActor
    func recommendationMappingUsesBrandCapsuleOnlyWhenReasonExists() throws {
        let video = RecommendedVideo(
            bvid: "BV-rcmd-stable",
            title: "首页推荐卡片",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 125,
            publishedAt: Date(timeIntervalSince1970: 0),
            recommendationReason: "正在流行"
        )

        let content = try #require(
            RecommendedNativeGridView.makePresentations([video, video]).first
        )
        #expect(RecommendedNativeGridView.makePresentations([video, video]).count == 1)
        #expect(content.footerTrailingText == "正在流行")
        #expect(content.footerTrailingStyle == .brandOutlinedCapsule)
        #expect(
            content.accessibilityLabel
                == RecommendedVideoCardPresentation(video: video).accessibilityLabel
        )

        let withoutReason = RecommendedVideo(
            bvid: "BV-rcmd-plain",
            title: video.title,
            coverURL: nil,
            owner: video.owner,
            statistics: video.statistics,
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            recommendationReason: nil
        )
        let plain = try #require(
            RecommendedNativeGridView.makePresentations([withoutReason]).first
        )
        #expect(plain.footerTrailingText == nil)
        #expect(plain.footerTrailingStyle == .plain)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }

    private func imageKey(
        _ path: String,
        variant: NativeVideoImageVariant = .cover
    ) -> NativeVideoImageKey {
        NativeVideoImageKey(
            url: URL(fileURLWithPath: "/native-video-cache/\(path)"),
            variant: variant
        )
    }
}
