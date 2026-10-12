import BiliModels
import CoreGraphics
import Foundation

/// 评论图片按用途请求的像素框，是唯一来源。
///
/// 列表格子按最大显示尺寸的 2 倍（Retina）请求缩小图，头像按解码上限请求；预览与表情请求原图。
/// 图床把图片按比例缩进框内、不放大，所以一个框覆盖所有格子尺寸。
enum NativePlaybackCommentAssetSizing {
    static let displayPixelScale: CGFloat = 2

    static func pixelBox(for variant: NativeVideoImageVariant) -> CommentAssetPixelBox? {
        switch variant {
        case .commentPicture:
            CommentAssetPixelBox(
                width: Int(
                    NativePlaybackCommentPictureLayout.maximumContentWidth * displayPixelScale
                ),
                height: Int(
                    NativePlaybackCommentPictureLayout.maximumImageHeight * displayPixelScale
                )
            )
        case .avatar:
            CommentAssetPixelBox(
                width: variant.maximumDecodedPixelSize,
                height: variant.maximumDecodedPixelSize
            )
        case .cover, .commentEmote, .commentPicturePreview, .trendingSearchIcon:
            nil
        }
    }
}

@MainActor
final class NativePlaybackCommentPictureLoader {
    private let imagePipeline: NativeVideoImagePipeline
    private let resolveURL: CommentAssetURLResolver
    private let variant: NativeVideoImageVariant

    init(
        imagePipeline: NativeVideoImagePipeline,
        resolveURL: @escaping CommentAssetURLResolver,
        variant: NativeVideoImageVariant = .commentPicture
    ) {
        self.imagePipeline = imagePipeline
        self.resolveURL = resolveURL
        self.variant = variant
    }

    func cachedImage(for reference: CommentAssetReference) -> CGImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedImage(for: url, variant: variant)
    }

    func cachedAnimation(for reference: CommentAssetReference) -> NativeAnimatedImage? {
        guard let url = url(for: reference) else { return nil }
        return imagePipeline.cachedAnimation(for: url, variant: variant)
    }

    func image(
        for reference: CommentAssetReference
    ) async -> NativeVideoImageLoadResult? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.image(for: url, variant: variant)
    }

    /// 保存原图用的原始数据与默认文件名（图床上的原文件名）。
    func originalData(for reference: CommentAssetReference) async -> Data? {
        guard let url = url(for: reference) else { return nil }
        return await imagePipeline.originalData(for: url, variant: variant)
    }

    /// 去掉开头的点，避免默认存成隐藏文件。
    func suggestedFileName(for reference: CommentAssetReference) -> String? {
        guard let name = url(for: reference)?.lastPathComponent else { return nil }
        let visible = String(name.drop(while: { $0 == "." }))
        guard !visible.isEmpty, visible != "/" else { return nil }
        return visible
    }

    private func url(for reference: CommentAssetReference) -> URL? {
        resolveURL(reference, NativePlaybackCommentAssetSizing.pixelBox(for: variant))
    }
}
