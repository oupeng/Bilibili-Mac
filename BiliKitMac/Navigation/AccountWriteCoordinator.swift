import BiliApplication
import BiliLibraryFeature
import Observation

/// 一个窗口里用户发起的账户写入的 owner：卡片菜单、读屏操作与 ⌘⌫ 发出的意图都交给它。
///
/// 拥有每个在途写入的 Task（同一视频的同一种写入同时只有一个）、写入结果胶囊显示的最新结果与它的消失计时，以及窗口复核
/// 的参与者代次。不拥有门槛的判断（`writableAccount` 由 `WindowComposition` 按窗口账户算出）、写请求本身（
/// `WatchLaterWriteUseCase`）、列表内容（稍后再看的乐观移除与回滚在 `WatchLaterViewModel`），也不直接刷新其他视图（效果交给
/// 本窗口的 `AccountWriteEffectRouter`，并经进程级集线器转给其他窗口）。
///
/// 每次执行都重新核对：卡片 ID 必须是合法 BVID、窗口此刻满足写入门槛，否则不发请求（菜单项可能是在门槛变化前构造的）。
/// 失败不重试、不排队；凭据类失败（`requiresAccountRevalidation`）递增一次复核代次，此后直到下一次写入成功都不再自动复核，
/// 避免“复核 → 仍失败 → 再复核”的循环。`close()`（关窗）取消全部在途写入与计时，之后不再接受意图；被取消的写入只回滚
/// 本地移除、不显示结果。
@MainActor
@Observable
final class AccountWriteCoordinator: AccountRevalidationParticipant {
    /// 写入结果胶囊停留的时长：够读完两行说明；读屏另有通告，不依赖胶囊停留。调长会让连续操作时旧结果盖住新内容更久。
    static let reportDisplayDuration: Duration = .seconds(4)

    /// 胶囊显示的最新结果；nil 时不显示。
    private(set) var report: AccountWriteReport?
    /// 每出现一条新结果递增；胶囊据此在相同结果连续出现时也重新通告。
    private(set) var reportSequence: UInt64 = 0
    /// 写入遇到凭据类失败时递增（`AccountRevalidationParticipant`），窗口汇总后复核一次。
    private(set) var authenticationRevalidationGeneration = 0

    @ObservationIgnored private let watchLater: WatchLaterWriteUseCase
    @ObservationIgnored private let watchLaterModel: WatchLaterViewModel
    @ObservationIgnored private let writableAccount: @MainActor () -> WritableAccount?
    @ObservationIgnored private let publish: @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    /// 在途写入，按改动去重；完成、失败或取消时移除。
    @ObservationIgnored private var inFlight: [AccountWriteChange: Task<Void, Never>] = [:]
    @ObservationIgnored private var reportDismissal: Task<Void, Never>?
    /// 已因凭据类失败请求过复核、此后还没有写入成功；为 true 时不再递增复核代次。
    @ObservationIgnored private var revalidationRequestedSinceSuccess = false
    @ObservationIgnored private var isClosed = false

    /// `publish` 把成功的效果交给本窗口的效果路由与其他窗口（`WindowComposition` 接线）。
    init(
        watchLater: WatchLaterWriteUseCase,
        watchLaterModel: WatchLaterViewModel,
        writableAccount: @escaping @MainActor () -> WritableAccount?,
        publish: @escaping @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    ) {
        self.watchLater = watchLater
        self.watchLaterModel = watchLaterModel
        self.writableAccount = writableAccount
        self.publish = publish
    }

    /// 写入门槛：窗口已确认登录且 mid 已知、不在复核中、没有待复核的外部换号，且窗口未关闭。菜单项据此启用或禁用。
    var isWritable: Bool {
        !isClosed && writableAccount() != nil
    }

    func addToWatchLater(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        start(.watchLaterAdded(target), account: account, appliedLocally: false) { [watchLater] in
            try await watchLater.add(target, accountID: account.accountID)
        }
    }

    /// 先在本窗口的稍后再看列表里乐观移除，失败或被取消时放回原位（列表此间被整体替换时由模型丢弃这次回滚）。
    func removeFromWatchLater(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        let change = AccountWriteChange.watchLaterRemoved(target)
        guard inFlight[change] == nil else { return }
        let removal = watchLaterModel.removeItem(bvid: bvid)
        start(
            change,
            account: account,
            appliedLocally: removal != nil,
            rollback: { [watchLaterModel] in
                if let removal { watchLaterModel.restoreItem(removal) }
            }
        ) { [watchLater] in
            try await watchLater.remove(target, accountID: account.accountID)
        }
    }

    /// 关窗：取消全部在途写入与胶囊计时，之后不再接受意图。不可逆。
    func close() {
        isClosed = true
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        reportDismissal?.cancel()
        reportDismissal = nil
        report = nil
    }

    private func currentAccount() -> WritableAccount? {
        guard !isClosed else { return nil }
        return writableAccount()
    }

    private func start(
        _ change: AccountWriteChange,
        account: WritableAccount,
        appliedLocally: Bool,
        rollback: @escaping @MainActor () -> Void = {},
        write: @escaping @MainActor () async throws -> AccountWriteEffect
    ) {
        guard inFlight[change] == nil else { return }
        inFlight[change] = Task { [weak self] in
            do {
                let effect = try await write()
                self?.finish(change, effect: effect, account: account, appliedLocally: appliedLocally)
            } catch is CancellationError {
                // 关窗，或认证会话在请求途中切换（API 按取消结束）：不显示结果，只撤销本地移除。
                rollback()
                self?.inFlight[change] = nil
            } catch {
                rollback()
                self?.fail(change, error: error as? AccountWriteError ?? .unavailable)
            }
        }
    }

    private func finish(
        _ change: AccountWriteChange,
        effect: AccountWriteEffect,
        account: WritableAccount,
        appliedLocally: Bool
    ) {
        inFlight[change] = nil
        guard !isClosed else { return }
        revalidationRequestedSinceSuccess = false
        show(AccountWriteReport(change: change, failure: nil))
        publish(
            AccountWriteEffectDelivery(effect: effect, sessionGeneration: account.sessionGeneration),
            appliedLocally
        )
    }

    private func fail(_ change: AccountWriteChange, error: AccountWriteError) {
        inFlight[change] = nil
        guard !isClosed else { return }
        show(AccountWriteReport(change: change, failure: error))
        if error.requiresAccountRevalidation, !revalidationRequestedSinceSuccess {
            revalidationRequestedSinceSuccess = true
            authenticationRevalidationGeneration &+= 1
        }
    }

    private func show(_ report: AccountWriteReport) {
        self.report = report
        reportSequence &+= 1
        let sequence = reportSequence
        reportDismissal?.cancel()
        reportDismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.reportDisplayDuration)
            guard !Task.isCancelled, let self, self.reportSequence == sequence else { return }
            self.report = nil
        }
    }
}
