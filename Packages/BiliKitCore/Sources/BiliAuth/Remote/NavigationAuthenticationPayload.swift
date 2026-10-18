import BiliModels
import BiliNetworking
import Foundation

/// `/x/web-interface/nav` 响应外层，由 `AuthenticationHTTP.navigationResult` 解释。
struct NavigationAuthenticationEnvelope: Decodable, Sendable {
    let code: Int
    let data: NavigationAuthenticationPayload?
}

/// nav 的 `data`：只解码 `isLogin` 与显示用的 MID、昵称、头像。
///
/// 身份字段缺失或不合法时仍算已登录，只是没有身份投影；头像地址经 BiliNetworking 的 `WebImageURL`
/// 升级为 HTTPS 并须通过公共 HTTPS 基线，不合规时只丢头像。
struct NavigationAuthenticationPayload: Decodable, Sendable {
    let isLogin: Bool
    private let mid: Int64?
    private let uname: String?
    private let face: String?

    private enum CodingKeys: String, CodingKey {
        case isLogin
        case mid
        case uname
        case face
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isLogin = try container.decode(Bool.self, forKey: .isLogin)
        mid = try? container.decode(Int64.self, forKey: .mid)
        uname = try? container.decode(String.self, forKey: .uname)
        face = try? container.decode(String.self, forKey: .face)
    }

    var authenticationResult: NavigationAuthenticationResult {
        guard isLogin else { return .signedOut }
        guard let mid, mid > 0, let uname else {
            return .signedIn(nil)
        }
        let displayName = uname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return .signedIn(nil) }
        return .signedIn(
            AccountIdentity(
                id: mid,
                displayName: displayName,
                avatarURL: face.flatMap(WebImageURL.parse)
            )
        )
    }
}

/// 一次 nav 校验的结论；已登录时身份投影可能缺失。
enum NavigationAuthenticationResult: Sendable, Equatable {
    case signedOut
    case signedIn(AccountIdentity?)
}

/// 恢复已存凭据的结论；`hadCredential` 区分“本来就没有凭据”与“凭据已失效并被清除”，
/// 后者需要传播会话失效。
enum StoredAccountSessionRestoreResult: Sendable, Equatable {
    case signedOut(hadCredential: Bool)
    case signedIn(AccountIdentity?)
}
