import BiliModels
import CoreGraphics
import Foundation

@MainActor
final class NativePlaybackCommentAvatarLoader {
    private let imagePipeline: any VideoDetailImageLoading
    private let resolveURL: CommentAssetURLResolver

    init(
        imagePipeline: any VideoDetailImageLoading,
        resolveURL: @escaping CommentAssetURLResolver
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedImage(for: url, purpose: .avatar)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> VideoDetailImage? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.image(for: url, purpose: .avatar)
    }

    private func url(for reference: CommentAssetReference) -> URL? {
        resolveURL(reference, NativePlaybackCommentAssetSizing.pixelBox(for: .avatar))
    }
}
