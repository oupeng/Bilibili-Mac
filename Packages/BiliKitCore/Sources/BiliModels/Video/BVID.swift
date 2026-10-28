import Foundation

/// BVID 形状与视频网页地址：`BV` 前缀加 1–22 位 ASCII 字母或数字，网页地址是 `https://www.bilibili.com/video/<BVID>`。
///
/// BiliAPI 用 BVID 拼 query 之前、映射远端条目与识别评论视频链接时，以及播放心跳授权器核对 Referer 时都用 `isValid`；
/// 视频请求的 Referer（BiliAPI `videoReferer`，加尾部斜杠）与卡片菜单的「拷贝链接」「在浏览器中打开」都由
/// `webPageURL` 派生；播放器动作菜单的链接带分 P 与时间，用 `webPageURL(_:pageNumber:startSeconds:)`。部分远端映射另有更严或更宽的筛选（例如只收 12 位 BVID），那是各自的数据规则，不是这里的形状。
/// 无状态。
public enum BVID {
    /// 视频网页地址的前缀；只拼合法 BVID，主机固定为 `www.bilibili.com`，见 SECURITY-MODEL §4。
    private static let webPagePrefix = "https://www.bilibili.com/video/"

    public static func isValid(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count > 2
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `https://www.bilibili.com/video/<BVID>`，不带尾部斜杠、query 与 fragment；BVID 不合法时为 nil。
    public static func webPageURL(_ bvid: String) -> URL? {
        guard isValid(bvid) else { return nil }
        return URL(string: webPagePrefix + bvid)
    }

    /// 带分 P 序号 `p` 与起播秒数 `t` 的视频网页地址，形状与评论里视频链接的解析一致；BVID 不合法时为 nil。
    ///
    /// `p`、`t` 只写正整数，nil 或非正数时不写这一项；两项都不写时与 `webPageURL(_:)` 相同。
    public static func webPageURL(_ bvid: String, pageNumber: Int?, startSeconds: Int?) -> URL? {
        guard let base = webPageURL(bvid),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        let items = [("p", pageNumber), ("t", startSeconds)].compactMap { name, value in
            value.flatMap { $0 > 0 ? URLQueryItem(name: name, value: String($0)) : nil }
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
