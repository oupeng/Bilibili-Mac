import BiliModels
import Foundation
import Testing

@testable import BiliVideoDetailFeature

/// 评论图片与头像按用途请求各自的像素框，保存原图的默认文件名取图床文件名且不成为隐藏文件。
@MainActor
struct NativePlaybackCommentAssetSizingTests {
    /// 列表按最大显示尺寸的 2 倍请求缩小图，头像按 `BiliAvatarImageSize` 请求；预览与表情请求原图。
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
        let pipeline = StubVideoDetailImageLoader()
        let reference = fixtureAssetReference()

        _ = NativePlaybackCommentPictureLoader(imagePipeline: pipeline, resolveURL: resolver)
            .cachedImage(for: reference)
        _ = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: resolver,
            purpose: .commentPicturePreview
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
        let pipeline = StubVideoDetailImageLoader()
        let reference = fixtureAssetReference()
        let requested = RequestedBoxes()

        let loader = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: { _, box in
                MainActor.assumeIsolated { requested.boxes.append(box) }
                return original
            },
            purpose: .commentPicturePreview
        )

        #expect(loader.suggestedFileName(for: reference) == "abc123.gif")
        #expect(requested.boxes == [nil])
        #expect(
            NativePlaybackCommentPictureLoader(
                imagePipeline: pipeline,
                resolveURL: { _, _ in nil },
                purpose: .commentPicturePreview
            )
            .suggestedFileName(for: reference) == nil
        )
    }

    /// 默认文件名去掉开头的点，不存成隐藏文件。
    @Test
    func savingNeverSuggestsAHiddenFileName() throws {
        let original = try #require(URL(string: "https://i0.hdslb.com/bfs/new_dyn/..abc.png"))
        let pipeline = StubVideoDetailImageLoader()

        let loader = NativePlaybackCommentPictureLoader(
            imagePipeline: pipeline,
            resolveURL: { _, _ in original },
            purpose: .commentPicturePreview
        )

        #expect(loader.suggestedFileName(for: fixtureAssetReference()) == "abc.png")
    }
}

@MainActor
private final class RequestedBoxes {
    var boxes: [CommentAssetPixelBox?] = []
}
