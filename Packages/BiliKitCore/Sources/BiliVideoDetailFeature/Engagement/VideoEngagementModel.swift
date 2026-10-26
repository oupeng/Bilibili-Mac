import BiliApplication
import BiliModels
import Observation

/// 播放页点赞、投币、收藏按钮的状态：当前账户对正在播放的视频做过什么（是否点赞、投了几枚币、是否收藏），按钮旁的
/// 计数，以及投币面板是否打开。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有互动状态的读取 Task（`present` 换视频或换账户时、`reload` 时发出，新读取
/// 替换旧读取，`reset` 取消）、本地对计数的增减与复核代次；不拥有写入（写入 Task 归 App 的写入协调者，它在写入前后调用
/// `applyLike`、`restore`、`applyCoins`、`applyTriple` 改这里的状态）。账户只从 App 注入的 `accountID` 闭包读取：它为
/// nil（未登录、认证仍在确认、其他窗口换号待复核）时不读取，按钮显示为禁用、计数照常。
@MainActor
@Observable
public final class VideoEngagementModel: AccountRevalidationParticipant {
    /// 互动状态的读取进度。
    public enum Phase: Sendable, Equatable {
        /// 没有可写入的账户或没有视频：不读取。
        case unavailable
        case loading
        case loaded(VideoEngagementState)
        case failed(ContentApplicationError)
    }

    /// 写入前的状态快照；写入失败或被取消时交回 `restore`。
    public struct Snapshot: Sendable {
        let bvid: String
        let generation: UInt64
        let state: VideoEngagementState
        let adjustment: CountAdjustment
    }

    /// 本地写入对接口计数的增减；换视频或拿到新详情时清零（新详情已含这些写入）。
    struct CountAdjustment: Sendable, Equatable {
        var likes: Int64 = 0
        var coins: Int64 = 0
        var favorites: Int64 = 0
    }

    public private(set) var phase = Phase.unavailable
    /// 正在显示的视频；没有时为 nil。
    public private(set) var bvid: String?
    /// 投币面板是否打开；按钮与快捷键 W 打开，面板关闭或投币后清除。
    public var isCoinPanelPresented = false
    public private(set) var authenticationRevalidationGeneration = 0

    private var summary = VideoEngagementSummary()
    private var baseLikeCount: Int64?
    private var adjustment = CountAdjustment()
    @ObservationIgnored private let useCase: VideoEngagementUseCase
    @ObservationIgnored private let accountID: @MainActor () -> Int64?
    @ObservationIgnored private let loadTask = LatestTask()
    /// 读取所属的账户；`present` 发现账户变了就重读。
    @ObservationIgnored private var loadedAccountID: Int64?
    /// 每次换视频、换账户或读取成功时递增；写入前的快照记下它，不符时 `restore` 不放回。
    @ObservationIgnored private var generation: UInt64 = 0
    /// 读取因凭据失败请求的复核进度：请求后等待；复核确认仍登录后自动重读一次，此后直到成功读取或换视频、换账户都不再
    /// 请求，挡住“复核 → 重读 → 失效 → 复核”的循环。
    @ObservationIgnored private var revalidation = RevalidationProgress.none

    private enum RevalidationProgress {
        case none
        case awaiting
        case reloaded
    }

    /// `accountID` 每次读取前求值，给出窗口此刻可写入的账户 mid（与写入门槛同一规则）。
    public init(useCase: VideoEngagementUseCase, accountID: @escaping @MainActor () -> Int64?) {
        self.useCase = useCase
        self.accountID = accountID
    }

    /// 已登录、读到了状态：按钮可用。
    public var engagement: VideoEngagementState? {
        if case .loaded(let state) = phase { state } else { nil }
    }

    public var likeCount: Int64? { baseLikeCount.map { max(0, $0 + adjustment.likes) } }
    public var coinCount: Int64? { summary.coinCount.map { max(0, $0 + adjustment.coins) } }
    public var favoriteCount: Int64? {
        summary.favoriteCount.map { max(0, $0 + adjustment.favorites) }
    }

    /// 还能投几枚；状态未知时为 0。
    public var remainingCoins: Int {
        guard let engagement else { return 0 }
        return VideoCoinRule.remainingCoins(
            isReposted: summary.isReposted,
            coinCount: engagement.coinCount
        )
    }

    /// 播放页出现、换视频、换分 P 或窗口账户变化时调用：视频或账户变了就丢弃旧状态并重读；同一视频拿到新详情时只换
    /// 计数。
    public func present(_ detail: VideoDetail?) {
        let account = accountID()
        guard let detail else {
            reset()
            return
        }
        let detailChanged =
            detail.bvid != bvid || detail.engagementSummary != summary
            || detail.statistics.likeCount != baseLikeCount
        if detailChanged {
            summary = detail.engagementSummary
            baseLikeCount = detail.statistics.likeCount
            adjustment = CountAdjustment()
        }
        guard detail.bvid != bvid || account != loadedAccountID else { return }
        bvid = detail.bvid
        isCoinPanelPresented = false
        revalidation = .none
        load(account: account, keepingState: false)
    }

    /// 别处的写入改了这个视频的互动（另一窗口点赞、「收藏到…」改了收藏）：正在显示它就重读，状态保持显示到新结果到达。
    public func markNeedsReload(bvid: String) {
        guard bvid == self.bvid, case .loaded = phase else { return }
        reload()
    }

    /// 失败后的重试与外部变化后的重读；已有状态时保持显示，新状态到达时计数按状态的变化增减（别处点了赞、改了收藏）。
    public func reload() {
        load(account: accountID(), keepingState: true)
    }

    /// 乐观点赞或取消：改状态与计数，返回写入失败时用来放回的快照；状态未知或不是这个视频时为 nil。
    ///
    /// 同时取消在途的读取：它是写入之前发出的，结果会把这次改动盖掉。
    public func applyLike(_ isLiked: Bool, bvid: String) -> Snapshot? {
        guard let snapshot = snapshot(for: bvid), snapshot.state.isLiked != isLiked else {
            return nil
        }
        loadTask.cancel()
        var state = snapshot.state
        state.isLiked = isLiked
        adjustment.likes += isLiked ? 1 : -1
        phase = .loaded(state)
        return snapshot
    }

    /// 写入失败的回滚；此间换了视频、换了账户或重读成功过时不放回，新状态已是服务端此刻的状态。
    public func restore(_ snapshot: Snapshot) {
        guard snapshot.bvid == bvid, snapshot.generation == generation else { return }
        adjustment = snapshot.adjustment
        phase = .loaded(snapshot.state)
    }

    /// 投币成功：已投数与计数加上这次的枚数，附带点赞成立时一并点赞。
    public func applyCoins(_ count: Int, alsoLiked: Bool, bvid: String) {
        guard var state = snapshot(for: bvid)?.state else { return }
        state.coinCount += count
        adjustment.coins += Int64(count)
        if alsoLiked, !state.isLiked {
            state.isLiked = true
            adjustment.likes += 1
        }
        phase = .loaded(state)
    }

    /// 三连成功：按服务端逐项结果补上此前没做的点赞与收藏，投币加上实际投出的枚数。
    public func applyTriple(_ outcome: VideoTripleOutcome, bvid: String) {
        guard var state = snapshot(for: bvid)?.state else { return }
        if outcome.isLiked, !state.isLiked {
            state.isLiked = true
            adjustment.likes += 1
        }
        if outcome.isFavorited, !state.isFavorited {
            state.isFavorited = true
            adjustment.favorites += 1
        }
        state.coinCount += outcome.addedCoinCount
        adjustment.coins += Int64(outcome.addedCoinCount)
        phase = .loaded(state)
    }

    /// 离开播放页、登出与关窗：取消读取并丢弃状态。
    public func reset() {
        loadTask.cancel()
        generation &+= 1
        bvid = nil
        loadedAccountID = nil
        summary = VideoEngagementSummary()
        baseLikeCount = nil
        adjustment = CountAdjustment()
        isCoinPanelPresented = false
        revalidation = .none
        phase = .unavailable
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 窗口复核确认仍已登录：本模型请求的复核在下一次成功读取前只自动重读一次。
    public func authenticationRevalidationSucceeded() {
        guard revalidation == .awaiting else { return }
        revalidation = .reloaded
        reload()
    }

    /// 同一视频的状态变了（别处的写入）：计数随之增减，接口计数要到下次拿到详情才更新。
    private func adjustCounts(from previous: VideoEngagementState, to state: VideoEngagementState) {
        adjustment.likes += Int64((state.isLiked ? 1 : 0) - (previous.isLiked ? 1 : 0))
        adjustment.coins += Int64(state.coinCount - previous.coinCount)
        adjustment.favorites += Int64((state.isFavorited ? 1 : 0) - (previous.isFavorited ? 1 : 0))
    }

    private func snapshot(for bvid: String) -> Snapshot? {
        guard bvid == self.bvid, let engagement else { return nil }
        return Snapshot(
            bvid: bvid,
            generation: generation,
            state: engagement,
            adjustment: adjustment
        )
    }

    /// `keepingState` 为 false（换视频、换账户）时先丢掉旧状态，避免把上一个视频或账户的状态当成这一个的。
    private func load(account: Int64?, keepingState: Bool) {
        loadTask.cancel()
        generation &+= 1
        loadedAccountID = account
        guard let account, account > 0, let bvid, let target = VideoWriteTarget(bvid: bvid) else {
            phase = .unavailable
            return
        }
        if !keepingState || engagement == nil { phase = .loading }
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            do {
                let state = try await useCase.engagement(of: target)
                guard let self, isCurrent() else { return }
                if let previous = engagement {
                    adjustCounts(from: previous, to: state)
                }
                generation &+= 1
                revalidation = .none
                phase = .loaded(state)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换，由账户变化重新 `present`。
                guard let self, isCurrent() else { return }
                if engagement == nil { phase = .unavailable }
            } catch {
                guard let self, isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                phase = .failed(failure)
                if failure == .authenticationRequired || failure.requiresAccountRevalidation,
                    revalidation == .none
                {
                    revalidation = .awaiting
                    authenticationRevalidationGeneration &+= 1
                }
            }
        }
    }
}
