import Foundation

/// 视频卡片（推荐、热门、搜索、观看历史）封面与作者头像的 B 站图片缩略地址。
///
/// 只改写 `hdslb.com` 及其子域、没有 query／fragment、path 里还没有缩略参数的地址；其他来源原样返回，
/// 来源校验仍由图片管线负责（见 SECURITY-MODEL §4）。缩略参数写在 path 上（`@{宽}w_{高}h_1c.webp`），
/// 让 CDN 按显示尺寸裁剪并转成 WebP，减少下载与解码。
package enum BiliImageThumbnail {
    package struct Size: Equatable {
        let width: Int
        let height: Int

        /// 16:9 封面：网格卡片在常见窗口宽度下约 240–320pt，2x 屏需要约 640 像素宽；
        /// 再大只增加下载与解码，卡片放大到超过 320pt 时略有模糊。
        package static let videoCover = Size(width: 640, height: 360)
        /// 卡片头像显示为 `VideoCardGeometry.avatarSize`（34pt），2x 屏约 68 像素，96 像素留出余量。
        package static let avatar = Size(width: 96, height: 96)
    }

    package static func url(_ url: URL?, size: Size) -> URL? {
        guard let url,
            let host = url.host?.lowercased(),
            host == "hdslb.com" || host.hasSuffix(".hdslb.com"),
            url.query == nil,
            url.fragment == nil,
            !url.path.contains("@")
        else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path += "@\(size.width)w_\(size.height)h_1c.webp"
        return components?.url ?? url
    }
}
