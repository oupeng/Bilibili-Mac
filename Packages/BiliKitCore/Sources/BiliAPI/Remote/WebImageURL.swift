import BiliNetworking
import Foundation

/// 接口返回的图片地址：`http:` 与协议相对地址升级为 HTTPS，再过公开 HTTPS 基线。
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
