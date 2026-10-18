import BiliNetworking
import Foundation

/// 接口返回的图片地址：`http:` 与协议相对地址升级为 HTTPS，再过公开 HTTPS 基线
/// `PublicHTTPSURLPolicy`。
///
/// 视频封面、头像、评论图片与热搜图标都先经过这里；评论资源与热搜图标另须通过
/// `BiliBFSImageURLPolicy`，图片管线请求前还会再检查（见 SECURITY-MODEL §4）。
enum WebImageURL {
    static func parse(_ value: String) -> URL? {
        let normalized: String
        if value.hasPrefix("//") {
            normalized = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            normalized = "https://" + value.dropFirst("http://".count)
        } else {
            normalized = value
        }
        guard let url = URL(string: normalized),
            PublicHTTPSURLPolicy().allows(url)
        else {
            return nil
        }
        return url
    }
}
