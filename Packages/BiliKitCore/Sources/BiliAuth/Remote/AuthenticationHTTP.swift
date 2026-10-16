import BiliNetworking
import Foundation

/// `BiliAuth` 自有网络的唯一 transport 配置与 nav 登录态校验形状。
///
/// 传输错误如何映射留给各调用方（QR 登录与 Keychain 恢复的失败语义不同）。
enum AuthenticationHTTP {
    enum NavigationValidationFailure: Error {
        case responseTooLarge
        case nonJSONResponse
        case invalidResponse
    }

    static let maximumResponseSize = 256 * 1_024
    /// QR 轮询与 nav 校验都是很小的 JSON：15 秒无数据或 30 秒未完成即按网络失败处理，让登录与启动
    /// 恢复及时报错；调大会让失败更晚出现，调小会让弱网下的正常请求被误判失败。
    private static let requestTimeout: TimeInterval = 15
    private static let resourceTimeout: TimeInterval = 30
    /// Cookie 已在服务端失效（被踢下线、改密）时 nav 的业务码，`data.isLogin` 同时为 false。
    static let notLoggedInCode = -101

    private static let navigationValidationURL: URL = {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
            preconditionFailure("Static navigation validation URL must be valid")
        }
        return url
    }()

    /// 无 Cookie storage、无 URL cache、拒绝 redirect 的 ephemeral transport。
    static func makeProductionTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.credentialFreeEphemeral()
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSessionTransport(
            configuration: configuration,
            redirectPolicy: .reject
        )
    }

    /// `cookieHeader` 为 nil 时由授权器从 Keychain 附加凭据。
    static func navigationValidationRequest(cookieHeader: String? = nil) -> HTTPRequest {
        var headers = [
            "Accept": "application/json",
            "Referer": "https://www.bilibili.com/",
            "User-Agent": HTTPUserAgent.short
        ]
        headers["Cookie"] = cookieHeader
        return HTTPRequest(url: navigationValidationURL, headers: headers)
    }

    static func navigationResult(
        from response: HTTPResponse
    ) throws(NavigationValidationFailure) -> NavigationAuthenticationResult {
        guard response.body.count <= maximumResponseSize else {
            throw .responseTooLarge
        }
        guard response.looksLikeJSON() else {
            throw .nonJSONResponse
        }
        guard
            let envelope = try? JSONDecoder().decode(
                NavigationAuthenticationEnvelope.self,
                from: response.body
            ),
            let data = envelope.data
        else {
            throw .invalidResponse
        }
        switch envelope.code {
        case 0:
            return data.authenticationResult
        case notLoggedInCode where !data.isLogin:
            // 服务端明确答复未登录，与 code 0 + isLogin false 同义；其他非 0 码仍失败关闭。
            return .signedOut
        default:
            throw .invalidResponse
        }
    }
}
