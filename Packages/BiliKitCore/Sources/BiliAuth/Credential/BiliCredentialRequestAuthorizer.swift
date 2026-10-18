import BiliNetworking
import Foundation

/// 两个授权器共用的失败；经 `authorizationFailureKind` 归入 BiliNetworking 的稳定分类。
///
/// 请求不在 allowlist 或调用方自带凭据 header 属于 `denied`（客户端编程错误）；
/// 本地无凭据才是 `missingCredential`；凭据损坏或过期在清除后归为 `invalidCredential`；
/// Keychain 不可用与校验不可用都是 `unavailable`（见 SECURITY-MODEL §3）。
public enum BiliRequestAuthorizationError:
    HTTPRequestAuthorizationFailure, Sendable, Equatable
{
    case requestNotAllowed
    case credentialHeaderAlreadyPresent
    case missingCredential
    case expiredCredential
    case invalidCredential
    case credentialStoreUnavailable
    case validationUnavailable

    public var authorizationFailureKind: HTTPRequestAuthorizationFailureKind {
        switch self {
        case .missingCredential:
            .missingCredential
        case .expiredCredential, .invalidCredential:
            .invalidCredential
        case .credentialStoreUnavailable, .validationUnavailable:
            .unavailable
        case .requestNotAllowed, .credentialHeaderAlreadyPresent:
            .denied
        }
    }
}

/// 从 Keychain 按需读取 Cookie，并只授权 Bilibili API 的只读账户请求。
///
/// 调用方声明账户读取能力后，scheme、host、port、method、exact path、userinfo、fragment 与
/// 现有凭据 header 仍会再次验证。损坏或过期凭据会清除，媒体/CDN/loopback 请求无法通过此边界
/// （见 SECURITY-MODEL §3）。不缓存 header：每次授权都重新读取 Keychain 并生成新请求。
public struct BiliCredentialRequestAuthorizer: HTTPRequestAuthorizing, Sendable {
    private let store: any WebCredentialStoring
    private let httpClient: HTTPClient
    private let transportInvalidator: (@Sendable () -> Void)?
    private let allowedPaths: Set<String>
    private let isConfirmedSignedOut: @Sendable () -> Bool

    /// `isConfirmedSignedOut` 为 true 时 Keychain 不可用按无凭据处理（由调用方决定能否匿名）；
    /// 认证服务自身的复核授权器不传，保持失败关闭。
    public init(
        allowedPaths: Set<String>,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool = { false }
    ) {
        let transport = AuthenticationHTTP.makeProductionTransport()
        store = KeychainWebCredentialStore()
        httpClient = HTTPClient(transport: transport)
        transportInvalidator = { transport.invalidateAndCancel() }
        self.allowedPaths = allowedPaths
        self.isConfirmedSignedOut = isConfirmedSignedOut
    }

    /// Keychain 与会话校验网络两个系统边界；public init 由此接入 Keychain store 与认证专用 session。
    init(
        store: any WebCredentialStoring,
        allowedPaths: Set<String>,
        transport: any HTTPTransport,
        isConfirmedSignedOut: @escaping @Sendable () -> Bool = { false }
    ) {
        self.store = store
        httpClient = HTTPClient(transport: transport)
        if let invalidating = transport as? any HTTPTransportInvalidating {
            transportInvalidator = { invalidating.invalidateAndCancel() }
        } else {
            transportInvalidator = nil
        }
        self.allowedPaths = allowedPaths
        self.isConfirmedSignedOut = isConfirmedSignedOut
    }

    /// 返回附带短生命周期 Cookie header 的新请求；原请求不会被原地共享或缓存。
    public func authorize(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard isAllowed(request) else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }
        guard !request.headers.containsCredentialHeader else {
            throw BiliRequestAuthorizationError.credentialHeaderAlreadyPresent
        }

        let credential: WebCredential
        do {
            guard let stored = try store.load() else {
                throw BiliRequestAuthorizationError.missingCredential
            }
            credential = stored
        } catch let error as BiliRequestAuthorizationError {
            throw error
        } catch WebCredentialStoreError.corruptCredential {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.invalidCredential
        } catch {
            guard isConfirmedSignedOut() else {
                throw BiliRequestAuthorizationError.credentialStoreUnavailable
            }
            throw BiliRequestAuthorizationError.missingCredential
        }

        guard !credential.isExpired() else {
            try purgeStoredCredential()
            throw BiliRequestAuthorizationError.expiredCredential
        }

        var headers = request.headers
        headers["Cookie"] = credential.cookieHeader
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
    }

    public func deleteStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }

    public func invalidateSession() {
        transportInvalidator?()
    }

    /// 验证已存凭据当前是否仍登录；明确失效会清除，验证不可用则保留并抛错。
    func restoreAccountSession() async throws -> StoredAccountSessionRestoreResult {
        let authorized: HTTPRequest
        do {
            authorized = try await authorize(
                AuthenticationHTTP.navigationValidationRequest()
            )
        } catch BiliRequestAuthorizationError.missingCredential {
            return .signedOut(hadCredential: false)
        } catch BiliRequestAuthorizationError.expiredCredential,
            BiliRequestAuthorizationError.invalidCredential
        {
            return .signedOut(hadCredential: true)
        }

        let response: HTTPResponse
        do {
            response = try await httpClient.send(authorized)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw BiliRequestAuthorizationError.validationUnavailable
        }
        guard
            let result = try? AuthenticationHTTP.navigationResult(from: response)
        else {
            throw BiliRequestAuthorizationError.validationUnavailable
        }
        guard case .signedIn(let identity) = result else {
            try purgeStoredCredential()
            return .signedOut(hadCredential: true)
        }
        return .signedIn(identity)
    }

    private func isAllowed(_ request: HTTPRequest) -> Bool {
        guard
            let components = URLComponents(
                url: request.url,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
        // 精确 host、端口与 GET，path 必须在 allowlist 里且编码规范；不用后缀匹配，见
        // SECURITY-MODEL §3。
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == "api.bilibili.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && allowedPaths.contains(components.path)
            && components.percentEncodedPath == components.path
            && components.fragment == nil
            && request.method == .get
    }

    private func purgeStoredCredential() throws {
        do {
            try store.delete()
        } catch {
            throw BiliRequestAuthorizationError.credentialStoreUnavailable
        }
    }
}

extension Dictionary where Key == String, Value == String {
    /// 调用方已自带凭据类 header 时，授权器拒绝而不覆盖；两个授权器共用这一判定。
    var containsCredentialHeader: Bool {
        keys.contains {
            $0.caseInsensitiveCompare("Cookie") == .orderedSame
                || $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("X-CSRF-Token") == .orderedSame
        }
    }
}
