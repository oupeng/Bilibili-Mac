import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
}

public struct HTTPRequest: Sendable, Equatable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?

    public init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

extension HTTPResponse {
    /// 解码前拒绝 HTML 风控页等非 JSON 响应：Content-Type 必须声明 JSON，正文须以对象（或允许时数组）开头。
    public func looksLikeJSON(allowsTopLevelArray: Bool = false) -> Bool {
        guard
            let contentType = headers.first(where: {
                $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
            })?.value.lowercased(),
            contentType.contains("json"),
            let firstByte = body.first(where: { ![9, 10, 13, 32].contains($0) })
        else {
            return false
        }
        return firstByte == 0x7B || (allowsTopLevelArray && firstByte == 0x5B)
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// 不包含业务或认证语义的 HTTP 传输边界，便于按用途注入独立 session。
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public protocol HTTPTransportInvalidating: Sendable {
    func invalidateAndCancel()
}

public enum HTTPClientError: Error, Sendable, Equatable {
    case nonHTTPResponse
    case unacceptableStatusCode(Int)
}

/// 只统一成功状态检查的轻量 client；来源、大小、Content-Type 与解码限制仍由调用方负责。
public actor HTTPClient {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func send(
        _ request: HTTPRequest,
        accepting acceptedStatusCodes: Range<Int> = 200..<300
    ) async throws -> HTTPResponse {
        let response = try await transport.send(request)
        guard acceptedStatusCodes.contains(response.statusCode) else {
            throw HTTPClientError.unacceptableStatusCode(response.statusCode)
        }
        return response
    }
}

extension URLSessionConfiguration {
    /// API、认证、媒体、字幕与图片 session 唯一的 ephemeral 基线：不自动附加 Cookie，没有 Cookie、
    /// 凭据与 URL cache（见 SECURITY-MODEL §4）。
    ///
    /// 调用方只在此基础上设置用途专属的超时与连接数，不得重新打开 Cookie、凭据或缓存；redirect 策略由
    /// 持有 session 的一方决定。需要账户凭据的请求只由授权器显式写入 header。
    public static func credentialFreeEphemeral() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// `URLSession` adapter：按调用方给出的用途专属配置与 redirect 策略自建并拥有 session。
///
/// 没有回落到 `URLSession.shared` 的入口（见 SECURITY-MODEL §1）。transport 释放时让 session 完成
/// 在途任务后失效，session 与 delegate 随之释放；`invalidateAndCancel` 立即取消在途请求。
public final class URLSessionTransport: HTTPTransport, HTTPTransportInvalidating,
    @unchecked Sendable
{
    private let session: URLSession

    public convenience init(
        configuration: URLSessionConfiguration,
        redirectPolicy: HTTPRedirectPolicy
    ) {
        let delegate: URLSessionTaskDelegate? =
            switch redirectPolicy {
            case .follow:
                nil
            case .reject:
                RejectHTTPRedirectDelegate()
            }
        self.init(
            session: URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
        )
    }

    /// 接管 `session` 的生命周期：transport 释放时让它失效。
    init(session: URLSession) {
        self.session = session
    }

    deinit {
        // 已被 `invalidateAndCancel` 失效的 session 再次失效是 no-op。
        session.finishTasksAndInvalidate()
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }

        let headers = httpResponse.allHeaderFields.reduce(
            into: [String: String](),
            { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        )

        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }

    public func invalidateAndCancel() {
        session.invalidateAndCancel()
    }
}

public enum HTTPRedirectPolicy: Sendable {
    case follow
    case reject
}

final class RejectHTTPRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
