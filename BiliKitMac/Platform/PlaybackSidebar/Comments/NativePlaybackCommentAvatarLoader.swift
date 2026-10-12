import BiliModels
import CoreGraphics
import Foundation

@MainActor
final class NativePlaybackCommentAvatarLoader {
    private let imagePipeline: NativeVideoImagePipeline
    private let resolveURL: CommentAssetURLResolver

    init(
        imagePipeline: NativeVideoImagePipeline,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedImage(for: url, variant: .avatar)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> NativeVideoImageLoadResult? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.image(for: url, variant: .avatar)
    }

    private func url(for reference: CommentAssetReference) -> URL? {
        resolveURL(reference, NativePlaybackCommentAssetSizing.pixelBox(for: .avatar))
    }
}
