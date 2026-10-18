import BiliModels
import BiliNetworking
import Foundation

/// 评论链接目标到可交给系统浏览器的网页地址；视频与时间戳在应用内处理，返回 nil。
///
/// 外链与短链（解析失败时的回退）只经 `PublicHTTPSURLPolicy` 形状复核，不预取、不解析 DNS、
/// 不附加凭据，见 SECURITY-MODEL §4。调用方是 App 的 `CommentLinkRouting`，
/// 以及正文网址识别（判断外链能否显示为链接）。无状态。
public struct BiliCommentLinkResolver: Sendable {
    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    public init() {}

    public func externalURL(for target: CommentLinkTarget) -> URL? {
        switch target {
        case .video, .timestamp:
            return nil
        case .member(let user):
            guard let memberID = user.id.memberID else { return nil }
            return Self.spaceURL(memberID)
        case .space(let memberID):
            guard memberID > 0 else { return nil }
            return Self.spaceURL(memberID)
        // 短链在这里只作解析失败时的回退：浏览器打开原短链，由 b23.tv 自己跳转。
        case .external(let reference), .shortLink(let reference):
            guard let url = reference.remoteURL,
                allowsUserInitiatedExternalURL(url)
            else { return nil }
            return url
        }
    }

    /// 成员与空间目标的网页空间地址；App 的评论路由把这两类目标直接打开为应用内空间，
    /// 不读取这里的结果。
    private static func spaceURL(_ memberID: Int64) -> URL? {
        URL(string: "https://space.bilibili.com/\(memberID)")
    }

    /// 公开 HTTPS 形状复核（见 SECURITY-MODEL §4）；fragment 不随请求发出，只在复核时去掉，
    /// 交给系统的仍是原地址。
    private func allowsUserInitiatedExternalURL(_ url: URL) -> Bool {
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        components.fragment = nil
        guard let validationURL = components.url else { return false }
        return publicHTTPSPolicy.allows(validationURL)
    }
}
