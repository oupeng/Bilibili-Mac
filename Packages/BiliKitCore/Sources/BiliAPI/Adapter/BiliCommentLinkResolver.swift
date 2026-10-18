import BiliModels
import BiliNetworking
import Foundation

/// 评论外链与短链到可交给系统浏览器的网页地址。
///
/// 外链与短链（解析失败时的回退）只经 `PublicHTTPSURLPolicy` 形状复核，不预取、不解析 DNS、
/// 不附加凭据，见 SECURITY-MODEL §4。视频、时间戳、@ 成员与空间链接都在应用内处理，不经这里。
/// 调用方是 App 的 `CommentLinkRouting`，以及正文网址识别（判断外链能否显示为链接）。无状态。
public struct BiliCommentLinkResolver: Sendable {
    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    public init() {}

    /// 通过复核时返回原地址，否则 nil；短链在这里只作解析失败时的回退，浏览器打开原短链，由 b23.tv 自己跳转。
    public func externalURL(for reference: CommentExternalLinkReference) -> URL? {
        let url = reference.remoteURL
        return allowsUserInitiatedExternalURL(url) ? url : nil
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
