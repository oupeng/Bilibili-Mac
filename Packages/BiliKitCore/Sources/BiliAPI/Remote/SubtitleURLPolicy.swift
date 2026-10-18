import Foundation

/// 字幕正文 URL 的来源规则：只接受 `https://aisubtitle.hdslb.com/bfs/...`，端口缺省或 443，不带
/// userinfo 与 fragment。
///
/// 目录映射时与 `BiliSubtitleRepository` 读取正文前各检查一次（见 SECURITY-MODEL §4）。
/// 该策略只判断来源形状；正文仍须用无 Cookie、无缓存且拒绝重定向的独立 transport 读取，
/// 不能把通过此检查等同于可复用认证会话。新主机先失败关闭，确认后再加入 allowlist。
struct SubtitleURLPolicy: Sendable {
    private let allowedHosts: Set<String> = [
        "aisubtitle.hdslb.com"
    ]

    func allows(_ url: URL) -> Bool {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased(),
            allowedHosts.contains(host),
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            components.fragment == nil,
            components.path.hasPrefix("/bfs/")
        else {
            return false
        }
        return true
    }
}
