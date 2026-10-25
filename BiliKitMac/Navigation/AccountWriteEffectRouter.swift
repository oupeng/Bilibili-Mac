import BiliApplication
import BiliLibraryFeature

/// 窗口账户此刻能否写入：窗口账户已确认登录且 mid 已知，并带上进程账户会话代次（`AccountSessionCoordinator.generation`）。
///
/// 由 `WindowComposition` 按与收藏夹列表相同的规则（`settledAccountScope`）算出：认证仍在确认、或其他窗口换号而本窗口还没
/// 复核到时为 nil。写入协调者据此决定门槛、写请求绑定哪个账户；效果路由据此丢弃不属于本窗口账户的效果。
struct WritableAccount: Equatable {
    let accountID: Int64
    let sessionGeneration: UInt64
}

/// 一次确认成功的写入效果，连同发起时的进程账户会话代次；在窗口之间经 `AccountWriteEffectHub` 传递。
struct AccountWriteEffectDelivery: Equatable {
    let effect: AccountWriteEffect
    let sessionGeneration: UInt64
}

/// 把写入效果落到本窗口的视图上：稍后再看列表只标记为过期，下次页面出现时原地刷新，不在后台读取。
///
/// 每个窗口一个，由 `WindowComposition` 构造；本窗口的写入协调者直接交给它，其他窗口的效果经进程级 `AccountWriteEffectHub`
/// 转来（窗口打开时登记、关闭时注销）。只处理与本窗口当前账户、会话代次都一致的效果，其余丢弃：换号或登出之后迟到的
/// 效果不能让新账户的列表刷新。不持有 Task 与状态，只引用窗口的模型。
@MainActor
final class AccountWriteEffectRouter {
    private let watchLaterModel: WatchLaterViewModel
    private let writableAccount: @MainActor () -> WritableAccount?

    init(
        watchLaterModel: WatchLaterViewModel,
        writableAccount: @escaping @MainActor () -> WritableAccount?
    ) {
        self.watchLaterModel = watchLaterModel
        self.writableAccount = writableAccount
    }

    /// `appliedLocally` 为 true 表示本窗口的视图已经按这次写入改过（稍后再看页的乐观移除），不再标记过期：否则刚移除
    /// 成功就会再刷新一次。
    func apply(_ delivery: AccountWriteEffectDelivery, appliedLocally: Bool) {
        guard
            let account = writableAccount(),
            account.accountID == delivery.effect.accountID,
            account.sessionGeneration == delivery.sessionGeneration
        else { return }
        switch delivery.effect.change {
        case .watchLaterAdded, .watchLaterRemoved:
            guard !appliedLocally else { return }
            watchLaterModel.markNeedsReload()
        }
    }
}
