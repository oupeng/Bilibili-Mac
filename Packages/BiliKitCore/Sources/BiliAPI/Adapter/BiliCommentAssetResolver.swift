import BiliModels
import Foundation

public struct BiliCommentAssetResolver: Sendable {
    public init() {}

    /// 返回评论图片地址；带像素框时改请求图床按框缩小的 WebP（`@{宽}w_{高}h.webp`），不带框为原图。
    ///
    /// 图床把图片按比例缩进框内、不放大；GIF 加此参数得到动态 WebP。缩略参数写在 path 上，结果仍须
    /// 通过同一来源规则；已带参数或框不合法的地址退回原图。
    public func imageURL(
        for reference: CommentAssetReference,
        fitting box: CommentAssetPixelBox?
    ) -> URL? {
        guard let url = reference.remoteURL, BiliBFSImageURLPolicy.allows(url) else {
            return nil
        }
        guard let box, box.width > 0, box.height > 0, !url.path.contains("@"),
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.percentEncodedPath += "@\(box.width)w_\(box.height)h.webp"
        guard let thumbnail = components.url, BiliBFSImageURLPolicy.allows(thumbnail) else {
            return url
        }
        return thumbnail
    }
}
