import BiliApplication
import BiliModels
import Foundation
import Observation

/// 资料库视频列表页的呈现状态，由 `LibraryVideoListModel.state` 从加载阶段与 `PagedVideoList` 投影得出。
///
/// `loaded` 的 continuation 为 nil 表示已到底；`loadingMore` 的 continuation 是正在请求的那一页。
public enum LibraryVideoListState<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: Sendable,
    Equatable
{
    case idle
    case loading
    case loaded(
        items: [Item],
        continuation: Cursor?,
        loadMoreError: ContentApplicationError?
    )
    case loadingMore(
        items: [Item],
        continuation: Cursor
    )
    case failed(ContentApplicationError)
}

/// 资料库里只按账户读取的视频列表（观看历史、稍后再看）共用的 ViewModel：拥有当前登录会话的列表
/// （`PagedVideoList`）、加载阶段、凭据复核状态与最新请求 Task。
///
/// 两个来源只在分页游标、第一页游标、无进展页策略与读取闭包上不同，由各自的构造入口给出（`WatchHistoryViewModel`、
/// `WatchLaterViewModel`）。游标是完整请求时（稍后再看的条件加页码），条件变化由来源的会话经
/// `reloadReplacingContent(from:)` 换掉第一页游标并重新加载；旧条件的迟到结果由 `LatestTask` 丢弃，旧条件的下一页
/// 游标也与新列表的游标不等而被 `PagedVideoList` 拒收。去重、上限、无进展页、回环、加载更多失败与原地刷新的分页恢复都由 `PagedVideoList`
/// 承担；空页跳过等来源规则在各自的 Use Case。`reset` 会清除个性化内容；普通路由停用只取消在途请求，并在分页或
/// 刷新中断时保留已显示条目。已有条目时刷新原地进行：条目保持显示，成功后整体替换，失败时保留条目并给出
/// `refreshError`；凭据缺失或失效则放弃条目、转入失败页并请求账户复核。
@MainActor
@Observable
public final class LibraryVideoListModel<
    Item: Sendable & Equatable,
    Cursor: Equatable & Sendable
>: AccountRevalidationParticipant {
    /// 读取一页：传入第一页游标（来源没有时为 nil）或列表给出的下一页游标，返回这一页与来源给出的总条数（没有时
    /// 为 nil）。失败抛出 `ContentApplicationError`，取消原样传播。
    typealias Load = @MainActor (Cursor?) async throws -> (page: VideoListPage<Item, Cursor>, totalCount: Int?)

    /// `phase` 与列表的投影；`.loadingMore` 时的 continuation 就是正在请求的那一页。
    public var state: LibraryVideoListState<Item, Cursor> {
        switch phase {
        case .idle:
            .idle
        case .loading:
            .loading
        case .failed(let error):
            .failed(error)
        case .loaded:
            if list.isLoadingMore, let continuation = list.nextCursor {
                .loadingMore(items: list.items, continuation: continuation)
            } else {
                .loaded(
                    items: list.items,
                    continuation: list.nextCursor,
                    loadMoreError: list.loadMoreError
                )
            }
        }
    }

    /// 每次加载成功（含首次加载与原地刷新）递增；App 只在它前进时把这个来源的网格滚回顶部。
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 最近一次原地刷新失败的原因，条目仍是刷新前的内容；下一次刷新开始时清除。
    public private(set) var refreshError: ContentApplicationError?
    /// 读取发现凭据失效时递增，由窗口汇总后复核账户（`AccountRevalidationParticipant`，与其他内容页同一契约）。
    ///
    /// 资料库列表只在已登录时渲染，所以读取时本地没有凭据也说明窗口的登录状态已过期，同样递增。
    public private(set) var authenticationRevalidationGeneration = 0
    /// 本页因凭据缺失或失效请求了账户复核、复核尚未结束；失败页据此显示“正在重新确认”。
    ///
    /// 复核结束（`authenticationRevalidationSucceeded`／`authenticationRevalidationFailed`）、
    /// 加载成功、离开页面或 `reset` 时清除。
    public private(set) var isAwaitingAuthenticationRevalidation = false
    /// 最近一次成功的第一页给出的总条数（来源给出时），条件下的总数随加载成功更新；首次加载、条件变化、失败与
    /// `reset` 时清空，只在已显示内容时有值。
    public private(set) var totalCount: Int?

    /// 已有条目时的原地刷新正在进行；首次加载仍是 `.loading`。
    public var isRefreshing: Bool {
        list.isRefreshing
    }

    /// 近尾自动加载的尾标计数，只供 renderer 对 near-end 事件去重，不编码远端游标；没有下一页、
    /// 需要显式继续、加载更多失败或原地刷新时为 nil。
    public var paginationTailIdentity: UInt64? {
        list.tailIdentity
    }

    /// 无进展页保留游标时（显式继续策略），必须由用户显式继续，避免 near-end 连续扫描；原地刷新期间收起，
    /// 刷新失败后恢复。停止策略的来源总是 false。
    public var requiresManualLoadMore: Bool {
        list.offersManualContinue
    }

    public var isBusy: Bool {
        switch phase {
        case .loading:
            true
        case .loaded:
            list.isRefreshing || list.isLoadingMore
        case .idle, .failed:
            false
        }
    }

    /// 列表页的加载阶段；已加载的条目与分页状态在 `list`。
    private enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(ContentApplicationError)
    }

    private var phase: Phase = .idle
    /// 只在 `phase == .loaded` 时被显示；首次加载、失败与 `reset` 时换成空列表，不留下旧账户的条目。
    private var list: PagedVideoList<Item, Cursor>

    /// 首次加载与刷新请求的第一页游标；观看历史为 nil，稍后再看是当前条件的第一页，条件变化时由
    /// `reloadReplacingContent(from:)` 替换。
    @ObservationIgnored private var firstPageCursor: Cursor?
    @ObservationIgnored private let stallPolicy: PagedVideoList<Item, Cursor>.StallPolicy
    @ObservationIgnored private let load: Load
    @ObservationIgnored private let bvid: (Item) -> String
    /// 刷新与加载更多共用的最新意图 Task：新请求替换旧请求，迟到结果经 `isCurrent` 丢弃；`reset` 与
    /// `deactivateRoute` 取消。
    @ObservationIgnored private let loadTask = LatestTask()
    /// 复核后已自动重载过一次，加载成功或 `reset` 时清除。
    ///
    /// 复核确认仍登录而重载又得到凭据失效时不再自动重载，挡住连续的“复核 → 重载 → 失效 → 复核”。
    @ObservationIgnored private var hasReloadedAfterRevalidation = false

    init(
        stallPolicy: PagedVideoList<Item, Cursor>.StallPolicy,
        firstPageCursor: Cursor? = nil,
        bvid: @escaping (Item) -> String,
        load: @escaping Load
    ) {
        self.firstPageCursor = firstPageCursor
        self.stallPolicy = stallPolicy
        self.bvid = bvid
        self.load = load
        list = PagedVideoList(stallPolicy: stallPolicy)
    }

    public func loadIfNeeded() {
        guard phase == .idle else { return }
        reload()
    }

    public func reload() {
        // 已有条目（或正在加载更多）时原地刷新，与首页、热门一致：网格不卸载，成功后由刷新代次回到顶部。
        let refreshesInPlace = phase == .loaded && (!list.items.isEmpty || list.isLoadingMore)
        refreshError = nil
        if refreshesInPlace {
            list.beginRefresh()
        } else {
            list = emptyList()
            totalCount = nil
            phase = .loading
        }
        let firstPageCursor = firstPageCursor
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let result = try await load(firstPageCursor)
                guard isCurrent() else { return }
                list.replaceFirstPage(result.page, bvid: bvid)
                totalCount = result.totalCount
                phase = .loaded
                successfulReloadGeneration &+= 1
                isAwaitingAuthenticationRevalidation = false
                hasReloadedAfterRevalidation = false
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。不是网络失败；已有条目原样保留，
                // 否则回到 idle，由会话切换后的复核与 `authenticationRevalidationSucceeded` 重新加载。
                guard isCurrent() else { return }
                if refreshesInPlace {
                    list.restoreAfterFailedRefresh()
                } else {
                    phase = .idle
                }
            } catch {
                guard isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                // 原地刷新失败保留已显示条目；凭据缺失或失效进入终态，条目不再显示。
                if refreshesInPlace, !Self.isCredentialFailure(failure) {
                    refreshError = failure
                    list.restoreAfterFailedRefresh()
                } else {
                    fail(failure)
                }
            }
        }
    }

    /// 近尾自动加载、显式继续与加载更多失败后的重试共用：请求列表给出的同一游标。
    public func loadMore() {
        guard phase == .loaded, let continuation = list.beginLoadMore() else { return }
        loadTask.replace { [weak self] isCurrent in
            guard let self else { return }
            do {
                let result = try await load(continuation)
                guard isCurrent() else { return }
                list.apply(result.page, requested: continuation, bvid: bvid)
            } catch is CancellationError {
                // 认证切换带来的取消只保留已显示条目，并要求用户显式继续。
                guard isCurrent() else { return }
                list.cancelLoadMore(requiringManualContinue: true)
            } catch {
                guard isCurrent() else { return }
                let failure = error as? ContentApplicationError ?? .unavailable
                // 与刷新一致：凭据缺失或失效时不再显示该账户的条目，转入失败页并请求复核。
                if Self.isCredentialFailure(failure) {
                    fail(failure)
                } else {
                    list.failLoadMore(failure)
                }
            }
        }
    }

    /// 换掉第一页游标（稍后再看的条件变化）并从空列表重新加载：不原地刷新，旧条件的条目不能留在新条件下显示；
    /// 加载成功时 `successfulReloadGeneration` 前进，App 据此把网格滚回顶部。
    func reloadReplacingContent(from firstPageCursor: Cursor) {
        self.firstPageCursor = firstPageCursor
        list = emptyList()
        phase = .idle
        reload()
    }

    /// 只换掉第一页游标、不发请求；来源会话在 `reset` 时把条件恢复为默认后调用。
    func replaceFirstPageCursor(_ firstPageCursor: Cursor) {
        self.firstPageCursor = firstPageCursor
    }

    /// 窗口的账户范围变化（登出、换号、凭据失效后确认的新范围）时由 App 通知，只在已解析的变化时调用。
    ///
    /// 丢弃上一账户的列表；新范围已登录且本来源是当前来源时立即重新加载，其他来源回来时由页面的
    /// `loadIfNeeded` 加载。不像 Browse 那样按账户会话代次去重：本方法只由本窗口账户范围的变化驱动，每次
    /// 变化调用一次；其他窗口换号时本窗口在复核前另行 `reset`，复核得出新范围后才走到这里，那时进程代次可能
    /// 已经不变，按代次去重会吞掉这次加载。
    public func synchronizeAuthenticationSession(
        scope: AccountSessionScope,
        isCurrentRoute: Bool
    ) {
        reset()
        guard case .signedIn = scope, isCurrentRoute else { return }
        loadIfNeeded()
    }

    /// 取消请求并从内存删除全部个性化条目，供登出、换号与窗口关闭调用。
    public func reset() {
        loadTask.cancel()
        list = emptyList()
        totalCount = nil
        refreshError = nil
        isAwaitingAuthenticationRevalidation = false
        hasReloadedAfterRevalidation = false
        phase = .idle
    }

    /// 停用页面请求而不抹掉已加载条目；迟到结果由 `LatestTask` 拒绝。
    ///
    /// 被打断的原地刷新恢复刷新前的分页，被打断的加载更多恢复开始前的显式继续门。离开页面后 App 不再把
    /// 复核结果交给本页：停止等待复核，凭据失败页回到 idle，回来时重新加载。
    public func deactivateRoute() {
        loadTask.cancel()
        refreshError = nil
        isAwaitingAuthenticationRevalidation = false
        list.restoreAfterFailedRefresh()
        list.cancelLoadMore(requiringManualContinue: false)
        switch phase {
        case .loading:
            phase = .idle
        case .failed(let failure) where Self.isCredentialFailure(failure):
            phase = .idle
        case .idle, .loaded, .failed:
            break
        }
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 账户复核确认仍已登录（或会话切换后重新确认）；窗口只在本来源是当前来源时调用。
    ///
    /// 本页因凭据失效请求的复核，确认后自动重载一次；同一会话内只做一次，之后再失效只显示失败、
    /// 由用户重试。其余情况只在 idle 时加载。
    public func authenticationRevalidationSucceeded() {
        let requestedRevalidation = isAwaitingAuthenticationRevalidation
        isAwaitingAuthenticationRevalidation = false
        guard requestedRevalidation, !hasReloadedAfterRevalidation else {
            loadIfNeeded()
            return
        }
        hasReloadedAfterRevalidation = true
        reload()
    }

    /// 账户复核没能确认登录状态（网络或 Keychain 不可用）；窗口只在本来源是当前来源时调用。
    ///
    /// 给出可重试的“无法读取登录状态”，不是网络失败。凭据失败时条目已清空；隐私清理仍由账户范围
    /// 变化负责。
    public func authenticationRevalidationFailed() {
        let requestedRevalidation = isAwaitingAuthenticationRevalidation
        isAwaitingAuthenticationRevalidation = false
        switch phase {
        case .idle:
            phase = .failed(.authenticationUnavailable)
        case .failed where requestedRevalidation:
            phase = .failed(.authenticationUnavailable)
        case .loading, .loaded, .failed:
            break
        }
    }

    private func emptyList() -> PagedVideoList<Item, Cursor> {
        PagedVideoList(stallPolicy: stallPolicy)
    }

    /// 凭据缺失或失效：原地刷新不保留条目，并请求窗口复核账户。
    private static func isCredentialFailure(_ error: ContentApplicationError) -> Bool {
        error == .authenticationRequired || error.requiresAccountRevalidation
    }

    /// 进入失败页并放弃已显示条目；凭据失败时请求账户复核。
    private func fail(_ failure: ContentApplicationError) {
        if Self.isCredentialFailure(failure) {
            isAwaitingAuthenticationRevalidation = true
            authenticationRevalidationGeneration &+= 1
        }
        list = emptyList()
        totalCount = nil
        phase = .failed(failure)
    }
}
