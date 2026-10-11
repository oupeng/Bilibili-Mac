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
}

@MainActor
private final class RequestedBoxes {
    var boxes: [CommentAssetPixelBox?] = []
}
