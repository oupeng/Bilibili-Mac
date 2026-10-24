import Foundation

/// BVID 形状与视频网页地址的唯一来源。
///
/// 形状是 `BV` 前缀加 1–22 位 ASCII 字母或数字。BiliAPI 用 BVID 拼 query、Referer，以及映射远端条目、识别评论
/// 视频链接之前都先过 `isValid`；卡片菜单的「拷贝链接」「在浏览器中打开」只用 `webPageURL` 给出的地址。无状态。
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
}
