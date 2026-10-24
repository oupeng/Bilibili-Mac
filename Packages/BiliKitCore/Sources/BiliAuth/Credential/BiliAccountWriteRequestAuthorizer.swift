import BiliNetworking
import Foundation

/// 只授权用户发起的账户写入（目前是稍后再看的加入与移除），并在 `BiliAuth` 内绑定账户、注入最小 Cookie 与 CSRF。
///
/// 每个请求必须精确命中：`https://api.bilibili.com`（端口缺省或 443）、POST、无 query／userinfo／fragment、path 同时在
/// Composition 声明的 allowlist 与本类型封闭的 schema 表里；header 集合固定为 `Accept`、`Content-Type`、`Origin`、
/// `Referer`、`User-Agent`，取值逐项相等，Referer 是该 path 规定的固定地址；表单不超过 `maximumBodySize`，字段名
/// 恰为 schema 的必需字段加可选字段的子集，取值形状逐项校验。调用方自带 `csrf`、Cookie 等凭据类字段或 header 的请求
/// 都不在 schema 内，一律拒绝。任一校验不通过都按 `requestNotAllowed`（客户端编程错误）拒绝，不尝试修正请求。
///
/// 每次授权都重新读 Keychain、不缓存：凭据的 `DedeUserID` 必须等于调用方给出的预期账户（`boundTo`），不符时按凭据失效
/// （`accountMismatch`）拒绝但不删除凭据，因为那多半是本窗口的账户范围过期、Keychain 里已是另一窗口登录的新账户。
/// Cookie 只放该 path 白名单里的项（目前只有 `SESSDATA`），`bili_jct` 只作为表单 `csrf` 拼在末尾。与观看进度的
/// `BiliPlaybackHeartbeatRequestAuthorizer` 相互独立，新增写操作在 schema 表里逐条登记，不泛化（见 SECURITY-MODEL §3）。
public struct BiliAccountWriteRequestAuthorizer: HTTPSubjectBoundRequestAuthorizing, Sendable {
    /// 一个写 path 的封闭表单 schema：必需与可选字段及其取值形状、固定 Referer 与要发送的 Cookie。
    struct Schema: Sendable {
        let requiredFields: [String: FieldShape]
        let optionalFields: [String: FieldShape]
        let referer: String
        /// 按 path 列出的 Cookie 白名单；需要更多 Cookie 的写操作（例如点赞要求的 `buvid3`）在自己的 schema 里扩展。
        let cookieNames: [WebCredentialCookieName]
    }

    /// 字段取值的形状。
    enum FieldShape: Sendable {
        /// 正整数（稿件 aid 等），只由 ASCII 数字组成。
        case positiveInteger

        func accepts(_ value: String) -> Bool {
            switch self {
            case .positiveInteger:
                WriteRequestAuthorizationSupport.positiveInteger(value)
                    && value.allSatisfy { $0.isASCII && $0.isNumber }
            }
        }
    }

    /// 全部可授权的写 path 与它们的 schema；path 字面量与 BiliAPI 的 `BiliAccountWritePath` 相同（BiliAuth 不能依赖
    /// BiliAPI，Composition 的测试核对两边一致）。
    ///
    /// 稍后再看移除用单条接口 `toview/del`（urlencoded、不签 WBI）：它有接口文档、多个第三方客户端在用，表单只有
    /// aid 与 csrf。网页稍后再看页实际用的是 `toview/v2/dels`（WBI 签名 + multipart），如果 `toview/del` 失效再换用它，
    /// 届时要在这里登记 multipart 的封闭解析与签名 query 的校验，不能放宽成接受任意正文。
    static let schemas: [String: Schema] = [
        "/x/v2/history/toview/add": Schema(
            requiredFields: ["aid": .positiveInteger],
            optionalFields: [:],
            referer: "https://www.bilibili.com/",
            cookieNames: [.session]
        ),
        "/x/v2/history/toview/del": Schema(
            requiredFields: ["aid": .positiveInteger],
            optionalFields: [:],
            referer: "https://www.bilibili.com/watchlater/",
            cookieNames: [.session]
        )
    ]

    /// 写请求固定的 `Origin`：浏览器跨域 POST 会带它，B 站据此与 Referer 一起判断来源。
    static let origin = "https://www.bilibili.com"
    /// 表单正文上限：现有 schema 只有一两个短字段，远小于 1 KiB，超出说明请求构造有误，直接拒绝。
    private static let maximumBodySize = 1_024
    private typealias Support = WriteRequestAuthorizationSupport

    private let store: any WebCredentialStoring
    private let allowedPaths: Set<String>

    /// `allowedPaths` 由 Composition 声明（窗口主 API 的写 allowlist），只有同时在 schema 表里的 path 可授权。
    public init(allowedPaths: Set<String>) {
        store = KeychainWebCredentialStore()
        self.allowedPaths = allowedPaths
    }

    /// Keychain 边界；`init(allowedPaths:)` 由此接入 Keychain store。
    init(store: any WebCredentialStoring, allowedPaths: Set<String>) {
        self.store = store
        self.allowedPaths = allowedPaths
    }

    /// `subject` 是窗口账户的 mid（十进制正整数）；返回附带短生命周期 Cookie 与 csrf 的新请求，原请求不被修改或缓存。
    public func authorize(
        _ request: HTTPRequest,
        boundTo subject: String
    ) async throws -> HTTPRequest {
        guard Support.positiveInteger(subject), subject.allSatisfy({ $0.isASCII && $0.isNumber }),
            let schema = schema(for: request),
            let body = request.body,
            body.count <= Self.maximumBodySize,
            let bodyString = String(data: body, encoding: .utf8),
            Self.matches(bodyString, schema: schema),
            Self.hasExactHeaders(request.headers, referer: schema.referer)
        else {
            throw BiliRequestAuthorizationError.requestNotAllowed
        }

        let credential = try store.loadCredentialForWrite()
        // 账户绑定：窗口以为的账户与 Keychain 里的凭据不是同一个时不发出写请求，见 SECURITY-MODEL §3。
        guard credential.value(for: .userID) == subject else {
            throw BiliRequestAuthorizationError.accountMismatch
        }
        let cookies = schema.cookieNames.map { name in
            credential.value(for: name).map { "\(name.rawValue)=\($0)" }
        }
        guard let csrf = credential.value(for: .csrf),
            let encodedCSRF = Support.encodedCSRFField(csrf),
            cookies.allSatisfy({ $0 != nil })
        else {
            throw BiliRequestAuthorizationError.invalidCredential
        }

        var headers = request.headers
        headers["Cookie"] = cookies.compactMap(\.self).joined(separator: "; ")
        return HTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: Data("\(bodyString)&\(encodedCSRF)".utf8)
        )
    }

    /// 目标精确、方法为 POST 且 path 同时在 allowlist 与 schema 表里时返回该 path 的 schema。
    private func schema(for request: HTTPRequest) -> Schema? {
        guard
            let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            components.host?.lowercased() == "api.bilibili.com",
            components.port == nil || components.port == 443,
            components.user == nil,
            components.password == nil,
            components.percentEncodedPath == components.path,
            components.percentEncodedQuery == nil,
            components.fragment == nil,
            request.method == .post,
            allowedPaths.contains(components.path)
        else { return nil }
        return Self.schemas[components.path]
    }

    private static func matches(_ body: String, schema: Schema) -> Bool {
        guard let fields = Support.decodedUniqueFields(body) else { return false }
        let names = Set(fields.keys)
        let required = Set(schema.requiredFields.keys)
        guard names.isSuperset(of: required),
            names.isSubset(of: required.union(schema.optionalFields.keys))
        else { return false }
        return fields.allSatisfy { name, value in
            (schema.requiredFields[name] ?? schema.optionalFields[name])?.accepts(value) ?? false
        }
    }

    private static func hasExactHeaders(_ headers: [String: String], referer: String) -> Bool {
        let normalized = Dictionary(grouping: headers, by: { $0.key.lowercased() })
        let expected: [String: String] = [
            "accept": "application/json",
            "content-type": "application/x-www-form-urlencoded",
            "origin": origin,
            "referer": referer,
            "user-agent": HTTPUserAgent.browserCompatible
        ]
        guard Set(normalized.keys) == Set(expected.keys) else { return false }
        return expected.allSatisfy { name, value in
            normalized[name]?.count == 1 && normalized[name]?.first?.value == value
        }
    }
}
