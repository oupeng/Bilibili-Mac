import BiliApplication
import BiliLibraryFeature
import BiliVideoDetailFeature
import Observation

/// 一个窗口里用户发起的账户写入的 owner：卡片菜单、读屏操作、⌘⌫、「收藏到…」面板，以及播放页的点赞、投币、三连按钮与
/// 快捷键发出的意图都交给它。
///
/// 拥有每个在途写入的 Task（同一改动同时只有一个）、正在显示的「收藏到…」面板（`favoritePicker`，同时只有一个；归属的
/// 读取 Task 归面板模型）、写入结果胶囊显示的最新结果与它的消失计时，以及窗口复核的参与者代次。不拥有门槛的判断
/// （`writableAccount` 由 `WindowComposition` 按窗口账户算出）、写请求本身（`WatchLaterWriteUseCase`、
/// `FavoritesWriteUseCase`、`VideoEngagementUseCase`）、列表与互动状态（乐观改动与回滚在 `WatchLaterViewModel`、
/// `FavoriteFolderViewModel`、`VideoEngagementModel`），也不直接刷新其他视图（效果交给本窗口的
/// `AccountWriteEffectRouter`，并经进程级集线器转给其他窗口）。
///
/// 每次执行都重新核对：卡片 ID 必须是合法 BVID、窗口此刻满足写入门槛，否则不发请求（菜单项可能是在门槛变化前构造的）。
/// 失败不重试、不排队；凭据类失败（`requiresAccountRevalidation`）递增一次复核代次，此后在同一账户与会话代次里直到下一次
/// 写入成功都不再自动复核，避免“复核 → 仍失败 → 再复核”；换号或登出再登录后会话代次变化，节流随之作废。面板绑定打开时
/// 的窗口账户（含会话代次）：窗口账户一变（`writableAccountDidChange`）就关闭，重试与确认前再核对一次，面板里的收藏夹
/// 与归属不会在另一个账户下显示、重读或提交。`close()`（关窗）关闭面板、取消全部在途写入与计时，之后不再接受意图；
/// 被取消的写入只回滚本地移除、不显示结果。
@MainActor
@Observable
final class AccountWriteCoordinator: AccountRevalidationParticipant {
    /// 写入结果胶囊停留的时长。
    ///
    /// 够读完两行说明；读屏另有通告，不依赖胶囊停留。调长会让连续操作时旧结果盖住新内容更久。
    static let reportDisplayDuration: Duration = .seconds(4)
    /// 带「在浏览器中打开」的结果停留的时长（`AccountWriteReport.webFallbackURL`）。
    ///
    /// 要留出读完说明、再把指针移过去点按的时间；调短来不及点，调长会久久盖住相关推荐。
    static let actionableReportDisplayDuration: Duration = .seconds(8)

    /// 胶囊显示的最新结果；nil 时不显示。
    private(set) var report: AccountWriteReport?
    /// 每出现一条新结果递增；胶囊据此在相同结果连续出现时也重新通告。
    private(set) var reportSequence: UInt64 = 0
    /// 写入遇到凭据类失败时递增（`AccountRevalidationParticipant`），窗口汇总后复核一次。
    private(set) var authenticationRevalidationGeneration = 0
    /// 正在显示的「收藏到…」面板，nil 时不显示。
    ///
    /// `AppShellView` 以它呈现 sheet。
    private(set) var favoritePicker: FavoritePickerModel?

    @ObservationIgnored private let watchLater: WatchLaterWriteUseCase
    @ObservationIgnored private let watchLaterModel: WatchLaterViewModel
    @ObservationIgnored private let favoritesWrite: FavoritesWriteUseCase
    /// 面板读取归属用的读取 use case。
    @ObservationIgnored private let favorites: FavoritesUseCase
    @ObservationIgnored private let favoriteFolders: FavoriteFolderViewModel
    @ObservationIgnored private let engagement: VideoEngagementUseCase
    @ObservationIgnored private let engagementModel: VideoEngagementModel
    @ObservationIgnored private let writableAccount: @MainActor () -> WritableAccount?
    @ObservationIgnored private let publish:
        @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    /// 在途写入，按改动去重；完成、失败或取消时移除。
    @ObservationIgnored private var inFlight: [AccountWriteChange: Task<Void, Never>] = [:]
    @ObservationIgnored private var reportDismissal: Task<Void, Never>?
    /// 因凭据类失败请求过复核时的账户与会话代次；此后还没有写入成功。
    ///
    /// 失败时的账户与它相同就不再递增复核代次；写入成功时清空，账户或会话代次不同（换号、登出再登录）时视为作废，避免
    /// 上一会话的节流让新会话的写入再也不复核。
    @ObservationIgnored private var revalidationRequestedFor: WritableAccount?
    /// 打开面板时的窗口账户；面板关闭时清空。
    @ObservationIgnored private var favoritePickerAccount: WritableAccount?
    @ObservationIgnored private var isClosed = false

    /// `publish` 把成功的效果交给本窗口的效果路由与其他窗口（`WindowComposition` 接线）。
    init(
        watchLater: WatchLaterWriteUseCase,
        watchLaterModel: WatchLaterViewModel,
        favoritesWrite: FavoritesWriteUseCase,
        favorites: FavoritesUseCase,
        favoriteFolders: FavoriteFolderViewModel,
        engagement: VideoEngagementUseCase,
        engagementModel: VideoEngagementModel,
        writableAccount: @escaping @MainActor () -> WritableAccount?,
        publish: @escaping @MainActor (AccountWriteEffectDelivery, _ appliedLocally: Bool) -> Void
    ) {
        self.watchLater = watchLater
        self.watchLaterModel = watchLaterModel
        self.favoritesWrite = favoritesWrite
        self.favorites = favorites
        self.favoriteFolders = favoriteFolders
        self.engagement = engagement
        self.engagementModel = engagementModel
        self.writableAccount = writableAccount
        self.publish = publish
    }

    /// 写入门槛：窗口已确认登录且 mid 已知、不在复核中、没有待复核的外部换号，且窗口未关闭；菜单项据此启用或禁用。
    var isWritable: Bool {
        !isClosed && writableAccount() != nil
    }

    /// 窗口此刻的写入账户；`AppShellView` 观察它的变化并调用 `writableAccountDidChange`。
    var currentWritableAccount: WritableAccount? {
        currentAccount()
    }

    func addToWatchLater(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        start(.watchLaterAdded(target), account: account) { [watchLater] in
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
            appliedLocally: { removal != nil },
            rollback: { [watchLaterModel] in
                if let removal { watchLaterModel.restoreItem(removal) }
            },
            write: { [watchLater] in
                try await watchLater.remove(target, accountID: account.accountID)
            }
        )
    }

    /// 点赞或取消：先在播放页的互动状态里乐观改动，失败或被取消时放回（此间换了视频或重读过时由模型丢弃这次回滚）。
    ///
    /// 同一视频反方向的改动还在途时不发：两个请求到达服务端的顺序不可知，最终状态可能与按钮相反。
    func setLiked(_ isLiked: Bool, bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        let change = AccountWriteChange.likeChanged(target, isLiked: isLiked)
        let opposite = AccountWriteChange.likeChanged(target, isLiked: !isLiked)
        guard inFlight[change] == nil, inFlight[opposite] == nil else { return }
        let snapshot = engagementModel.applyLike(isLiked, bvid: bvid)
        start(
            change,
            account: account,
            appliedLocally: { snapshot != nil },
            rollback: { [engagementModel] in
                if let snapshot { engagementModel.restore(snapshot) }
            },
            write: { [engagement] in
                try await engagement.setLiked(isLiked, target: target, accountID: account.accountID)
            }
        )
    }

    /// 投币：成功后才改播放页的已投数与计数（不可撤回，不做乐观改动）。
    func addCoins(_ count: Int, alsoLike: Bool, bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        start(
            .coinsAdded(target, count: count, alsoLiked: alsoLike),
            account: account,
            appliedLocally: { true },
            write: { [engagement, engagementModel] in
                let effect = try await engagement.addCoins(
                    count,
                    alsoLike: alsoLike,
                    target: target,
                    accountID: account.accountID
                )
                if case .coinsAdded(_, let added, let liked) = effect.change {
                    engagementModel.applyCoins(added, alsoLiked: liked, bvid: bvid)
                }
                return effect
            }
        )
    }

    /// 三连：成功后按服务端逐项结果改播放页的状态；收藏进默认收藏夹，由效果路由刷新收藏夹。
    func triple(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        start(
            .tripled(target, nil),
            account: account,
            appliedLocally: { true },
            write: { [engagement, engagementModel] in
                let effect = try await engagement.triple(
                    target: target,
                    accountID: account.accountID
                )
                if case .tripled(_, let outcome?) = effect.change {
                    engagementModel.applyTriple(outcome, bvid: bvid)
                }
                return effect
            }
        )
    }

    /// 打开这个视频的「收藏到…」面板并读取归属。
    ///
    /// 已有面板时换成新的（旧面板的读取取消）；门槛不满足时不打开。
    func chooseFavoriteFolders(bvid: String) {
        guard let target = VideoWriteTarget(bvid: bvid), let account = currentAccount() else {
            return
        }
        favoritePicker?.cancel()
        let picker = FavoritePickerModel(
            target: target,
            accountID: account.accountID,
            useCase: favorites,
            onCredentialFailure: { [weak self] in self?.requestRevalidation(for: account) }
        )
        favoritePicker = picker
        favoritePickerAccount = account
        picker.load()
    }

    /// 面板的取消，以及 sheet 被系统关闭。
    func dismissFavoritePicker() {
        favoritePicker?.cancel()
        favoritePicker = nil
        favoritePickerAccount = nil
    }

    /// 面板读取失败后的重试：窗口账户已不是打开面板时的账户就关闭面板，否则重读。
    ///
    /// 面板的读取固定用打开时的 mid；账户变了还重读，就会用新账户的 Cookie 读旧账户的 mid（见 SECURITY-MODEL §3）。
    func retryFavoritePicker() {
        guard let picker = favoritePicker else { return }
        guard currentAccount() == favoritePickerAccount else {
            dismissFavoritePicker()
            return
        }
        picker.load()
    }

    /// 窗口的写入账户变了（登出、换号、其他窗口换号待复核、会话代次变化）：属于旧账户的面板立即关闭，它列出的收藏夹
    /// 与归属不再显示。
    func writableAccountDidChange() {
        guard favoritePicker != nil, currentAccount() != favoritePickerAccount else { return }
        dismissFavoritePicker()
    }

    /// 面板的确认：关闭面板，有改动时提交。
    ///
    /// 窗口账户此刻必须仍是打开面板时的账户：换号或登出后面板里的归属属于上一账户，按它提交会改动错的账户，直接丢弃。
    func confirmFavoritePicker() {
        guard let picker = favoritePicker else { return }
        let pickerAccount = favoritePickerAccount
        dismissFavoritePicker()
        guard let change = picker.change,
            let account = currentAccount(),
            account == pickerAccount
        else { return }
        start(.favoriteMembershipChanged(change), account: account) { [favoritesWrite] in
            try await favoritesWrite.update(change, accountID: account.accountID)
        }
    }

    /// 收藏夹页的「从此收藏夹移除」：先在显示中的收藏夹里乐观移除，失败或被取消时放回原位（此间内容被整体替换时由模型
    /// 丢弃这次回滚）。
    ///
    /// 写入成功时页面是否仍是移除后的样子在那一刻判断：期间刷新落地（或仍在途）会带回写入前的快照，这时要让效果路由
    /// 重读，不能沿用开始时“已在本地改过”的结论。
    func removeFromFavoriteFolder(_ entry: FavoriteFolderEntry) {
        guard let account = currentAccount() else { return }
        let change = AccountWriteChange.removedFromFavoriteFolder(entry)
        guard inFlight[change] == nil else { return }
        let removal = favoriteFolders.removeItem(entry)
        start(
            change,
            account: account,
            appliedLocally: { [favoriteFolders] in
                removal.map(favoriteFolders.stillShowsRemoval) ?? false
            },
            rollback: { [favoriteFolders] in
                if let removal { favoriteFolders.restoreItem(removal) }
            },
            write: { [favoritesWrite] in
                try await favoritesWrite.remove(entry, accountID: account.accountID)
            }
        )
    }

    /// 关窗：关闭面板，取消全部在途写入与胶囊计时，之后不再接受意图；不可逆。
    func close() {
        dismissFavoritePicker()
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

    /// `appliedLocally` 在写入成功时求值：本窗口的视图此刻是否已经是写入后的样子。
    private func start(
        _ change: AccountWriteChange,
        account: WritableAccount,
        appliedLocally: @escaping @MainActor () -> Bool = { false },
        rollback: @escaping @MainActor () -> Void = {},
        write: @escaping @MainActor () async throws -> AccountWriteEffect
    ) {
        guard inFlight[change] == nil else { return }
        inFlight[change] = Task { [weak self] in
            do {
                let effect = try await write()
                self?.finish(
                    change,
                    effect: effect,
                    account: account,
                    appliedLocally: appliedLocally
                )
            } catch is CancellationError {
                // 关窗，或认证会话在请求途中切换（API 按取消结束）：不显示结果，只撤销本地移除。
                rollback()
                self?.inFlight[change] = nil
            } catch {
                rollback()
                self?.fail(
                    change,
                    error: error as? AccountWriteError ?? .unavailable,
                    account: account
                )
            }
        }
    }

    private func finish(
        _ change: AccountWriteChange,
        effect: AccountWriteEffect,
        account: WritableAccount,
        appliedLocally: @MainActor () -> Bool
    ) {
        inFlight[change] = nil
        guard !isClosed else { return }
        revalidationRequestedFor = nil
        show(AccountWriteReport(change: change, failure: nil))
        publish(
            AccountWriteEffectDelivery(
                effect: effect,
                sessionGeneration: account.sessionGeneration
            ),
            appliedLocally()
        )
    }

    private func fail(
        _ change: AccountWriteChange,
        error: AccountWriteError,
        account: WritableAccount
    ) {
        inFlight[change] = nil
        guard !isClosed else { return }
        show(AccountWriteReport(change: change, failure: error))
        if error.requiresAccountRevalidation {
            requestRevalidation(for: account)
        }
    }

    /// 写入或面板读取遇到凭据类失败：同一账户与会话代次里只请求一次复核，直到下一次写入成功。
    private func requestRevalidation(for account: WritableAccount) {
        guard !isClosed, revalidationRequestedFor != account else { return }
        revalidationRequestedFor = account
        authenticationRevalidationGeneration &+= 1
    }

    private func show(_ report: AccountWriteReport) {
        self.report = report
        reportSequence &+= 1
        let sequence = reportSequence
        reportDismissal?.cancel()
        reportDismissal = Task { [weak self] in
            try? await Task.sleep(
                for: report.webFallbackURL == nil
                    ? Self.reportDisplayDuration : Self.actionableReportDisplayDuration
            )
            guard !Task.isCancelled, let self, self.reportSequence == sequence else { return }
            self.report = nil
        }
    }
}
