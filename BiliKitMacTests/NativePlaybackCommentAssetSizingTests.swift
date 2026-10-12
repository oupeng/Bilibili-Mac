import BiliModels
import Foundation
import Testing

@testable import BiliKit

@MainActor
struct NativePlaybackCommentAssetSizingTests {
    /// 列表按最大显示尺寸的 2 倍请求缩小图，头像按解码上限请求；预览与表情请求原图。
    @Test
    func eachUseRequestsItsOwnPixelBox() {
        #expect(
            NativePlaybackCommentAssetSizing.pixelBox(for: .commentPicture)
                == CommentAssetPixelBox(width: 728, height: 360)
        )
        #expect(
            NativePlaybackCommentAssetSizing.pixelBox(for: .avatar)
                == CommentAssetPixelBox(width: 96, height: 96)
        )
        #expect(NativePlaybackCommentAssetSizing.pixelBox(for: .commentPicturePreview) == nil)
        #expect(NativePlaybackCommentAssetSizing.pixelBox(for: .commentEmote) == nil)
    }

    @Test
    func loadersAskTheResolverForTheirUsesBox() {
        let requested = RequestedBoxes()
        let resolver: CommentAssetURLResolver = { _, box in
            MainActor.assumeIsolated { requested.boxes.append(box) }
            return nil
        }
        let pipeline = NativeVideoImagePipeline()
        defer { pipeline.shutdown() }
        let reference = CommentAssetReference()

        _ = NativePlaybackCommentPictureLoader(imagePipeline: pipeline, resolveURL: resolver)
            .cachedImage(for: reference)
        _ = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: resolver,
            variant: .commentPicturePreview
        )
        .cachedImage(for: reference)
        _ = NativePlaybackCommentAvatarLoader(imagePipeline: pipeline, resolveURL: resolver)
            .cachedImage(for: reference)

        #expect(
            requested.boxes == [
                NativePlaybackCommentAssetSizing.pixelBox(for: .commentPicture),
                nil,
                NativePlaybackCommentAssetSizing.pixelBox(for: .avatar)
            ]
        )
    }

    /// 保存原图的默认文件名取预览用的原图地址的文件名；解析不出地址时没有默认名。
    @Test
    func savingSuggestsTheOriginalFileName() throws {
        let original = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/abc123.gif"))
        let pipeline = NativeVideoImagePipeline()
        defer { pipeline.shutdown() }
        let reference = CommentAssetReference()
        let requested = RequestedBoxes()

        let loader = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: { _, box in
                MainActor.assumeIsolated { requested.boxes.append(box) }
                return original
            },
            variant: .commentPicturePreview
        )

        #expect(loader.suggestedFileName(for: reference) == "abc123.gif")
        #expect(requested.boxes == [nil])
        #expect(
            NativePlaybackCommentPictureLoader(
                imagePipeline: pipeline,
                resolveURL: { _, _ in nil },
                variant: .commentPicturePreview
            )
            .suggestedFileName(for: reference) == nil
        )
    }

    /// 默认文件名去掉开头的点，不存成隐藏文件。
    @Test
    func savingNeverSuggestsAHiddenFileName() throws {
        let original = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/..abc.png"))
        let pipeline = NativeVideoImagePipeline()
        defer { pipeline.shutdown() }

        let loader = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: { _, _ in original },
            variant: .commentPicturePreview
        )

        #expect(loader.suggestedFileName(for: CommentAssetReference()) == "abc.png")
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
        let pipeline = NativeVideoImagePipeline()
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
}

@MainActor
private final class RequestedBoxes {
    var boxes: [CommentAssetPixelBox?] = []
}
