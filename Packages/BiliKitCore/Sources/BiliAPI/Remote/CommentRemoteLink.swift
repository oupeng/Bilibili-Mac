import BiliModels
import Foundation

/// 评论 `jump_url` 的一项：键是正文里被替换的文字，值给出去向。
struct CommentJumpURLPayload: Decodable, Sendable {
    let pcURL: String?
    /// 搜索词链接：点击会离开播放去搜索页，与应用动线冲突，不生成链接。
    let isWordSearch: Bool

    private enum CodingKeys: String, CodingKey {
        case pcURL = "pc_url"
        case extra
    }

    private struct ExtraPayload: Decodable, Sendable {
        let isWordSearch: Bool?

        private enum CodingKeys: String, CodingKey {
            case isWordSearch = "is_word_search"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isWordSearch = container.decodeLossyBool(forKey: .isWordSearch)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pcURL = try container.decodeIfPresent(String.self, forKey: .pcURL)
        let extra = try? container.decodeIfPresent(ExtraPayload.self, forKey: .extra)
        isWordSearch = extra?.isWordSearch == true
    }

    /// 链接地址：`pc_url` 缺失或为空时，正文里的网址本身（如 b23.tv 短链）就是键，退回用键。
    ///
    /// 键不是 HTTPS 网址时由分类规则拒绝，不会生成链接。
    func destination(label: String) -> String {
        guard let pcURL, !pcURL.isEmpty else { return label }
        return pcURL
    }
}

/// 把评论链接地址分成站内视频、UP 主空间与其他 HTTPS 外链。
///
/// 站内目标按未解码的 host 与 path 精确匹配，不带端口；形状不符时不猜测，按外链处理。
enum CommentRemoteLink {
    /// 视频页所在的主机：桌面版、手机版与不带 `www` 的裸域。
    private static let videoHosts: Set<String> = [
        "www.bilibili.com", "m.bilibili.com", "bilibili.com"
    ]
    private static let spaceHost = "space.bilibili.com"
    /// 空间里与应用内空间层（投稿列表）对应的子页面；合集、收藏夹、动态等其他子页面交给浏览器。
    private static let spaceVideoListPaths: Set<[String]> = [[], ["video"], ["upload", "video"]]

    /// 短链主机；`bili2233.cn` 等其他短链域名不认，按外链处理。
    private static let shortLinkHost = "b23.tv"
    /// 短码只允许 ASCII 字母与数字，长度有上限。
    private static let maximumShortLinkCodeLength = 16

    static func target(_ value: String?) -> CommentLinkTarget? {
        guard let components = components(value) else { return nil }
        if let target = internalTarget(components) {
            return target
        }
        guard let url = components.url else { return nil }
        if shortLinkURL(components) != nil {
            return .shortLink(CommentExternalLinkReference(remoteURL: url))
        }
        return .external(CommentExternalLinkReference(remoteURL: url))
    }

    /// 合规短链的请求地址：只保留 `https://b23.tv/{短码}`，去掉 query 与 fragment；形状不符时为 nil。
    static func shortLinkRequestURL(_ url: URL) -> URL? {
        URLComponents(url: url, resolvingAgainstBaseURL: false).flatMap(shortLinkURL)
    }

    /// 地址是否在短链主机上，不论形状；短链解析不追第二跳。
    static func isOnShortLinkHost(_ url: URL?) -> Bool {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .percentEncodedHost?.lowercased() == shortLinkHost
    }

    private static func shortLinkURL(_ components: URLComponents) -> URL? {
        guard components.scheme?.lowercased() == "https",
            components.user == nil, components.password == nil, components.port == nil,
            components.percentEncodedHost?.lowercased() == shortLinkHost
        else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/")
        guard parts.count == 1, let code = parts.first,
            (1...maximumShortLinkCodeLength).contains(code.count),
            code.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else { return nil }
        return URL(string: "https://\(shortLinkHost)/\(code)")
    }

    private static func internalTarget(_ components: URLComponents) -> CommentLinkTarget? {
        guard components.port == nil, let host = components.percentEncodedHost?.lowercased()
        else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/").map(String.init)
        if videoHosts.contains(host), parts.count == 2, parts[0] == "video",
            let bvid = bvid(fromVideoID: parts[1])
        {
            return .video(bvid: bvid, page: pageNumber(in: components))
        }
        let memberID: Int64?
        if host == spaceHost, let first = parts.first,
            spaceVideoListPaths.contains(Array(parts.dropFirst()))
        {
            memberID = Int64(positiveDecimal: first)
        } else if host == "m.bilibili.com", parts.count == 2, parts[0] == "space" {
            memberID = Int64(positiveDecimal: parts[1])
        } else {
            memberID = nil
        }
        return memberID.map { .space(memberID: $0) }
    }

    /// 视频号：`BV…` 原样校验；`av…` 在本地换算为 BV 号。
    ///
    /// 链接路径与正文纯文字识别共用这一规则。
    static func bvid(fromVideoID component: String) -> String? {
        if BiliAPIClient.isValidBVID(component) {
            return component
        }
        guard component.lowercased().hasPrefix("av"),
            let aid = Int64(positiveDecimal: component.dropFirst(2))
        else { return nil }
        return BiliVideoAID.bvid(fromAID: aid)
    }

    /// 链接里的分 P 序号只是偏好：不是正整数时忽略，按视频默认分 P 打开。
    private static func pageNumber(in components: URLComponents) -> Int? {
        guard let value = components.queryItems?.first(where: { $0.name == "p" })?.value,
            let page = Int64(positiveDecimal: value)
        else { return nil }
        return Int(exactly: page)
    }

    private static func components(_ value: String?) -> URLComponents? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:\(value)" }
        guard let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil
        else { return nil }
        return components
    }
}
