import BiliModels
import Foundation

/// 评论资源引用到图片地址的唯一生成处：来源规则与缩略参数只在这里，见
/// docs/ARCHITECTURE.md「模块与依赖方向」的补充规则。
///
/// 无状态；App 经窗口级的 `CommentAssetURLResolver` 闭包调用（`WindowAdapters.live`），
/// 下载与响应校验在 App 图片管线。来源只认 `BiliBFSImageURLPolicy`，
/// 加缩略参数后的地址再过一次同一规则，见 SECURITY-MODEL §4。
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
        let url = reference.remoteURL
        guard BiliBFSImageURLPolicy.allows(url) else {
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
