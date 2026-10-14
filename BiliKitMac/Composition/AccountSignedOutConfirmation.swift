import BiliAuthFeature
import Synchronization

/// 本窗口的认证状态是否已确认未登录（不是恢复中、未知或不可用）。
///
/// 只供该窗口主 API 的授权器在 Keychain 不可用时判断：已确认未登录就按无凭据处理，游客内容照常
/// 匿名请求；会话未确认或已登录时仍失败关闭，不让已登录用户在不知情时降级为匿名。
final class AccountSignedOutConfirmation: Sendable {
    private let isSignedOut = Mutex(false)

    var isConfirmed: Bool {
        isSignedOut.withLock { $0 }
    }

    func synchronize(_ scope: AccountSessionScope) {
        isSignedOut.withLock { $0 = scope == .signedOut }
    }
}
