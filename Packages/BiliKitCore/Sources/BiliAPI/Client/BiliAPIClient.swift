import BiliApplication
import BiliModels
import BiliNetworking
import Foundation

/// Bilibili endpoint/DTO adapter；把远端协议限制在 `BiliAPI`，并返回稳定模型。
///
/// 请求默认匿名，只有 `RequestAccess.accountRead` 才经过 authorizer。允许游客增强的读取
/// 也只有在本地明确无凭据时保持匿名，并继续使用同一个 endpoint。
/// 响应在解码前还要满足状态、大小与 Content-Type 边界。actor 隔离可变
/// transport/WBI cache；跨 `await` 可重入，用户意图的取消与写回代次仍由上层 owner 管理。
///
/// 本文件只含请求管线（access 选择、授权、epoch 复核、envelope 解码）、WBI key 与签名读取序列
/// （`signedRequest`）；各域 endpoint 在同 actor 的 `BiliAPIClient+*.swift` 扩展中，签名读取一律经
/// `signedRequest`。`RequestAccess` 与管线方法对 `BiliAPI` 内部可见
/// 只为这些扩展；Repository adapter 只调用 endpoint 方法，不得自行构造 `RequestAccess`。
public actor BiliAPIClient: AuthenticatedSessionInvalidating {
    enum MissingCredentialBehavior: Sendable, Equatable {
        case fail
        case useAnonymousRequest
    }

    enum RequestAccess: Sendable {
        case anonymous
        case accountRead(missingCredential: MissingCredentialBehavior)
        case historyWrite

        var requiresAuthentication: Bool {
            switch self {
            case .anonymous: false
            case .accountRead, .historyWrite: true
            }
        }

        var permitsMissingCredentialFallback: Bool {
            guard case .accountRead(let behavior) = self else { return false }
            return behavior == .useAnonymousRequest
        }
    }

    enum AuthorizationProvenance: Sendable {
        case anonymous
        case authenticated

        /// 读取响应的业务码 -101（账号未登录）对应的错误；其他业务码为 nil。
        ///
        /// 只有实际带凭据发出的请求收到 -101 才是凭据失效（触发账户复核）。匿名请求（含本地无凭据时的
        /// 匿名回退）收到 -101 说明该接口要求登录，按“需要登录”处理，不触发复核。heartbeat 写请求另有
        /// 自己的判定。
        func notLoggedInError(statusCode: Int) -> BiliAPIError? {
            guard statusCode == -101 else { return nil }
            return self == .authenticated ? .authenticationInvalid : .authorizationRequired
        }
    }

    struct AuthorizedResponse<Payload: Sendable>: Sendable {
        let payload: Payload
        let authorizationProvenance: AuthorizationProvenance
    }

    struct AuthorizedHTTPResponse: Sendable {
        let response: HTTPResponse
        let authorizationProvenance: AuthorizationProvenance
    }

    private static let baseURL: URL = {
        guard let url = URL(string: "https://api.bilibili.com") else {
            preconditionFailure("Static API base URL must be valid")
        }
        return url
    }()

    private static let maximumResponseSize = 5 * 1_024 * 1_024

    /// 搜索接口要求的 `buvid3`，进程内随机生成一次，只附加到搜索请求。
    ///
    /// 只在内存中，不持久化、不关联账户；格式与 yt-dlp 相同（小写 UUID + `infoc`）。
    static let searchBuvid3Cookie = "buvid3=\(UUID().uuidString.lowercased())infoc"

    private var httpClient: HTTPClient
    private var transport: any HTTPTransport
    private let transportFactory: @Sendable () -> any HTTPTransport
    private let requestAuthorizer: (any HTTPRequestAuthorizing)?
    private let historyWriteAuthorizer: (any HTTPRequestAuthorizing)?
    let userAgent = HTTPUserAgent.browserCompatible
    let decoder: JSONDecoder
    let timestampProvider: @Sendable () -> Int64
    let wbiSigner = WBISigner()
    private var cachedWBIKey: CachedWBIKey?
    private(set) var authenticatedSessionEpoch: UInt64 = 0

    /// 端点扩展只需知道是否注入了授权器；授权器本身不离开请求管线。
    var hasAccountAuthorizer: Bool { requestAuthorizer != nil }
    var hasHistoryWriteAuthorizer: Bool { historyWriteAuthorizer != nil }

    /// `transportFactory` 由组合根提供用途专属 transport：初始化时取一次，每次认证会话失效时再取一个
    /// 干净实例替换旧的；不存在回落到 `URLSession.shared` 的默认值（见 SECURITY-MODEL §1）。
    public init(
        requestAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        historyWriteAuthorizer: (any HTTPRequestAuthorizing)? = nil,
        transportFactory: @escaping @Sendable () -> any HTTPTransport,
        timestampProvider: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        }
    ) {
        let activeTransport = transportFactory()
        transport = activeTransport
        httpClient = HTTPClient(transport: activeTransport)
        self.transportFactory = transportFactory
        self.requestAuthorizer = requestAuthorizer
        self.historyWriteAuthorizer = historyWriteAuthorizer
        self.timestampProvider = timestampProvider
        decoder = JSONDecoder()
    }

    /// 认证会话失效时取消旧 transport 请求、换入干净 session，并丢弃关联 WBI key。
    public func invalidateAuthenticatedSession() {
        authenticatedSessionEpoch &+= 1
        if let invalidating = transport as? any HTTPTransportInvalidating {
            invalidating.invalidateAndCancel()
        }
        let replacement = transportFactory()
        transport = replacement
        httpClient = HTTPClient(transport: replacement)
        cachedWBIKey = nil
    }

    /// 不关心授权来源时的薄封装。
    func get<Payload: Decodable & Sendable>(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize
    ) async throws -> Payload {
        try await getWithAuthorizationProvenance(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize
        ).payload
    }

    /// JSON GET 的唯一管线：请求、授权、状态码与 envelope 解码，并返回授权来源。
    func getWithAuthorizationProvenance<
        Payload: Decodable & Sendable
    >(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedResponse<Payload> {
        let authorizedResponse = try await response(
            url: url,
            referer: referer,
            access: access,
            maximumResponseSize: maximumResponseSize,
            additionalCookie: additionalCookie
        )
        let response = authorizedResponse.response

        let status: APIStatusEnvelope
        do {
            status = try decoder.decode(APIStatusEnvelope.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        if let error = authorizedResponse.authorizationProvenance.notLoggedInError(
            statusCode: status.code
        ) {
            throw error
        }
        guard status.code == 0 else {
            throw BiliAPIError.apiRejected(
                code: status.code,
                message: status.message ?? ""
            )
        }
        if Self.isRiskControlVoucher(response.body) {
            throw BiliAPIError.riskControlVoucher
        }
        let envelope: APIEnvelope<Payload>
        do {
            envelope = try decoder.decode(APIEnvelope<Payload>.self, from: response.body)
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let payload = envelope.data else {
            throw BiliAPIError.missingData
        }
        return AuthorizedResponse(
            payload: payload,
            authorizationProvenance:
                authorizedResponse.authorizationProvenance
        )
    }

    func response(
        url: URL,
        referer: String,
        access: RequestAccess = .anonymous,
        maximumResponseSize: Int = BiliAPIClient.maximumResponseSize,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        let baseRequest = HTTPRequest(
            url: url,
            headers: [
                "Accept": "application/json",
                "Referer": referer,
                "User-Agent": userAgent
            ]
        )
        let response = try await response(
            baseRequest: baseRequest,
            access: access,
            maximumResponseSize: maximumResponseSize,
            additionalCookie: additionalCookie
        )
        guard response.response.looksLikeJSON(allowsTopLevelArray: true) else {
            throw BiliAPIError.nonJSONResponse
        }
        return response
    }

    /// `additionalCookie` 只承载 endpoint 要求的非秘密 Cookie，在授权之后并入请求，
    /// 因此不会绕过授权器对调用方自带 Cookie 的拒绝。
    func response(
        baseRequest: HTTPRequest,
        access: RequestAccess,
        maximumResponseSize: Int,
        additionalCookie: String? = nil
    ) async throws -> AuthorizedHTTPResponse {
        let requestClient = httpClient
        let requestSessionEpoch =
            access.requiresAuthentication ? authenticatedSessionEpoch : nil
        var request: HTTPRequest
        let authorizationProvenance: AuthorizationProvenance
        let activeAuthorizer: (any HTTPRequestAuthorizing)? =
            switch access {
            case .historyWrite:
                historyWriteAuthorizer
            case .accountRead:
                requestAuthorizer
            case .anonymous:
                nil
            }
        if access.requiresAuthentication, let activeAuthorizer {
            do {
                request = try await activeAuthorizer.authorize(baseRequest)
                authorizationProvenance = .authenticated
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as any HTTPRequestAuthorizationFailure {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                switch error.authorizationFailureKind {
                case .missingCredential where access.permitsMissingCredentialFallback:
                    request = baseRequest
                    authorizationProvenance = .anonymous
                case .invalidCredential:
                    throw BiliAPIError.authenticationInvalid
                case .missingCredential:
                    throw BiliAPIError.authorizationRequired
                case .unavailable:
                    throw BiliAPIError.authorizationUnavailable
                case .denied:
                    // 请求形状或 path 不在授权器 allowlist：客户端构造了不该发出的账户请求，属于编程错误，
                    // 不是本地凭据问题，因此不显示为 Keychain 类失败。
                    throw BiliAPIError.invalidRequest
                }
            } catch {
                guard requestSessionEpoch == authenticatedSessionEpoch else {
                    throw CancellationError()
                }
                throw BiliAPIError.authorizationUnavailable
            }
        } else if access.permitsMissingCredentialFallback {
            request = baseRequest
            authorizationProvenance = .anonymous
        } else if access.requiresAuthentication {
            throw BiliAPIError.authorizationRequired
        } else {
            request = baseRequest
            authorizationProvenance = .anonymous
        }
        if let additionalCookie {
            var headers = request.headers
            headers["Cookie"] = [headers["Cookie"], additionalCookie]
                .compactMap { $0 }
                .joined(separator: "; ")
            request = HTTPRequest(
                url: request.url,
                method: request.method,
                headers: headers,
                body: request.body
            )
        }
        try Task.checkCancellation()
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        let response: HTTPResponse
        do {
            response = try await requestClient.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPClientError {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            throw BiliAPIError(error)
        } catch {
            if let requestSessionEpoch,
                requestSessionEpoch != authenticatedSessionEpoch
            {
                throw CancellationError()
            }
            throw BiliAPIError.transportFailure
        }
        if let requestSessionEpoch,
            requestSessionEpoch != authenticatedSessionEpoch
        {
            throw CancellationError()
        }

        guard response.body.count <= maximumResponseSize else {
            throw BiliAPIError.responseTooLarge(response.body.count)
        }
        return AuthorizedHTTPResponse(
            response: response,
            authorizationProvenance: authorizationProvenance
        )
    }

    /// WBI 签名读取的唯一序列：取 key、签名、请求与会话 epoch 复核都在这里，endpoint 只给出 path、
    /// 参数与发送方式。
    ///
    /// 进入时记录认证会话 epoch；取 key 之后与 `send` 返回之后都比对，不一致抛 `CancellationError`，
    /// 结果既不写回也不以新会话、新 key 或匿名身份补发。`parameters` 每次尝试都重新求值，`send` 拿到
    /// 本次尝试用当前 key 与时间戳签好的 URL，自行决定授权方式与解码；重试规则见
    /// `withWBIKeyRefresh`。heartbeat 写请求不经过这里：写入不做换 key 重试。
    func signedRequest<Value>(
        path: String,
        intermittentRestrictionRetryDelay: Duration? = nil,
        parameters: () -> [String: String],
        send: (_ url: URL) async throws -> Value
    ) async throws -> Value {
        let sessionEpoch = authenticatedSessionEpoch
        return try await withWBIKeyRefresh(
            sessionEpoch: sessionEpoch,
            intermittentRestrictionRetryDelay: intermittentRestrictionRetryDelay
        ) { forceKeyRefresh in
            let keys = try await wbiKey(forceRefresh: forceKeyRefresh)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            let query = try wbiSigner.sign(
                parameters: parameters(),
                keys: keys,
                timestamp: timestampProvider()
            )
            let value = try await send(try endpoint(path: path, percentEncodedQuery: query))
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return value
        }
    }

    /// WBI 签名请求的唯一重试策略：任何组合下最多请求两次。
    ///
    /// 首次请求被 -403 或 `v_voucher` 挑战拒绝时强制刷新 WBI key 再请求一次。HTTP 403／412 是风控而不是
    /// key 过期，默认按受限失败关闭；只有传入 `intermittentRestrictionRetryDelay` 的调用方在首次请求被
    /// HTTP 412 拒绝时等待后用同一个 key 再请求一次，等待期间会话变化则取消。重试的结果不再进入任何重试。
    private func withWBIKeyRefresh<Value>(
        sessionEpoch: UInt64,
        intermittentRestrictionRetryDelay: Duration?,
        _ request: (_ forceKeyRefresh: Bool) async throws -> Value
    ) async throws -> Value {
        do {
            return try await request(false)
        } catch BiliAPIError.apiRejected(let code, _) where code == -403 {
            return try await request(true)
        } catch BiliAPIError.riskControlVoucher {
            return try await request(true)
        } catch BiliAPIError.httpStatus(412) {
            guard let intermittentRestrictionRetryDelay else {
                throw BiliAPIError.httpStatus(412)
            }
            try await Task.sleep(for: intermittentRestrictionRetryDelay)
            try requireAuthenticatedSessionEpoch(sessionEpoch)
            return try await request(false)
        }
    }

    /// 只有 `data` 恰好是 `{"v_voucher": …}` 才算挑战；正常响应里并列的 `v_voucher` 不影响解码。
    private static func isRiskControlVoucher(_ body: Data) -> Bool {
        guard body.range(of: Data(#""v_voucher""#.utf8)) != nil,
            let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let data = root["data"] as? [String: Any]
        else { return false }
        return data.count == 1 && data["v_voucher"] != nil
    }

    func requireAuthenticatedSessionEpoch(_ expected: UInt64) throws {
        guard authenticatedSessionEpoch == expected else {
            throw CancellationError()
        }
    }

    func wbiKey(forceRefresh: Bool) async throws -> WBIKeyMaterial {
        let currentDay = timestampProvider() / 86_400
        if forceRefresh {
            cachedWBIKey = nil
        } else if let cachedWBIKey, cachedWBIKey.day == currentDay {
            return cachedWBIKey.key
        }

        // 会话失效会清掉缓存的 key；nav 返回前会话已失效时不把迟到的 key 写回去。
        let sessionEpoch = authenticatedSessionEpoch
        let url = try endpoint(path: "/x/web-interface/nav", queryItems: [])
        let response = try await response(
            url: url,
            referer: "https://www.bilibili.com/"
        ).response
        let envelope: APIEnvelope<NavigationPayload>
        do {
            envelope = try decoder.decode(
                APIEnvelope<NavigationPayload>.self,
                from: response.body
            )
        } catch {
            throw BiliAPIError.decodingFailed
        }
        guard let image = envelope.data?.wbiImage else {
            throw BiliAPIError.invalidWBIKey
        }
        let key = try WBIKeyMaterial(
            imageURL: image.imageURL,
            subURL: image.subURL
        )
        if authenticatedSessionEpoch == sessionEpoch {
            cachedWBIKey = CachedWBIKey(key: key, day: currentDay)
        }
        return key
    }

    func endpoint(
        path: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        try endpoint(path: path) { $0.queryItems = queryItems }
    }

    /// WBI 签名后的 query 已按签名顺序编码，必须原样使用。
    func endpoint(
        path: String,
        percentEncodedQuery: String
    ) throws -> URL {
        try endpoint(path: path) { $0.percentEncodedQuery = percentEncodedQuery }
    }

    private func endpoint(
        path: String,
        applyingQuery applyQuery: (inout URLComponents) -> Void
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: Self.baseURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw BiliAPIError.invalidRequest
        }
        components.path = path
        applyQuery(&components)
        guard let url = components.url else {
            throw BiliAPIError.invalidRequest
        }
        return url
    }

    static func isValidBVID(_ bvid: String) -> Bool {
        bvid.hasPrefix("BV")
            && bvid.count > 2
            && bvid.count <= 24
            && bvid.dropFirst(2).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func videoReferer(_ bvid: String) -> String {
        "https://www.bilibili.com/video/\(bvid)/"
    }
}

private struct CachedWBIKey: Sendable {
    let key: WBIKeyMaterial
    let day: Int64
}

struct APIStatusEnvelope: Decodable, Sendable {
    let code: Int
    let message: String?
}

private struct APIEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
}
