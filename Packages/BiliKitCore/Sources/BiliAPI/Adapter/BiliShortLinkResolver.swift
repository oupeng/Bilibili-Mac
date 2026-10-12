import BiliModels
import BiliNetworking
import Foundation

/// 评论里的 b23.tv 短链：用户点击后读一次跳转目标，再按评论链接的同一规则分类。
///
/// 无凭据、不跟随跳转的 `HEAD` 请求，不读正文；只接受一次 3xx 的绝对或协议相对 `Location`。目标仍在
/// 短链主机（不论形状）、不是跳转或请求失败时返回 nil，由调用方把原短链交给浏览器。不记录短码与目标地址。
public struct BiliShortLinkResolver: Sendable {
    /// 单次解析的时限；超时后回退到浏览器打开原短链。
    static let timeout: TimeInterval = 5
    private static let redirectStatusCodes: Set<Int> = [301, 302, 303, 307, 308]

    private let transport: any HTTPTransport

    public init() {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        self.init(
            transport: URLSessionTransport(
                configuration: configuration,
                redirectPolicy: .reject
            )
        )
    }

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// 窗口关闭时取消在途请求并释放 session。
    public func invalidate() {
        (transport as? any HTTPTransportInvalidating)?.invalidateAndCancel()
    }

    public func resolve(_ target: CommentLinkTarget) async -> CommentLinkTarget? {
        guard case .shortLink(let reference) = target,
            let url = reference.remoteURL.flatMap(CommentRemoteLink.shortLinkRequestURL),
            let response = try? await transport.send(HTTPRequest(url: url, method: .head)),
            Self.redirectStatusCodes.contains(response.statusCode),
            let location = response.headers.first(where: {
                $0.key.caseInsensitiveCompare("Location") == .orderedSame
            })?.value,
            let resolved = CommentRemoteLink.target(location)
        else { return nil }
        switch resolved {
        case .shortLink, .timestamp:
            return nil
        case .external(let reference) where CommentRemoteLink.isOnShortLinkHost(reference.remoteURL):
            return nil
        case .video, .member, .space, .external:
            return resolved
        }
    }
}
