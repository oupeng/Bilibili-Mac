/// 接口与评论正文里远端地址的协议补全与 `http://` 升级，只做字符串前缀改写，不解析 URL。
///
/// 图片地址（`WebImageURL`）、评论链接、字幕目录与正文网址识别共用这里；哪种地址升级、哪种拒绝由各调用方
/// 决定（见 SECURITY-MODEL §4）。刻意不用 `URLComponents` 改 scheme：`http:host` 这类无斜杠写法会被它解析成
/// 有 scheme 的地址并被改成 `https:host`，而字符串规则让它原样留给调用方的来源校验拒绝。
package enum RemoteURLString {
    /// `//` 开头的协议相对地址补成 `https:`；其他原样返回。
    package static func resolvingProtocolRelative(_ value: String) -> String {
        value.hasPrefix("//") ? "https:\(value)" : value
    }

    /// 不分大小写以 `http://` 开头时换成 `https://` 并标记已升级；其他原样返回，`upgraded` 为 false。
    package static func upgradingInsecureHTTP(_ value: String) -> (String, upgraded: Bool) {
        let prefix = "http://"
        guard value.lowercased().hasPrefix(prefix) else { return (value, false) }
        return ("https://" + value.dropFirst(prefix.count), true)
    }
}
