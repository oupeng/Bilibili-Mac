import BiliApplication
import BiliModels
import Foundation
import Observation

/// 收藏夹来源的 ViewModel：选中的收藏夹、夹内的排序与关键词、按页整体替换的当前页，以及请求与复核。
///
/// 每个窗口一份，由 App 的窗口组装构造，绑定收藏夹来源（只在本页时读取，见 SECURITY-MODEL §3）。拥有选中的收藏夹 ID、
/// 条件（排序菜单的选择与已应用的排序、搜索框草稿与已应用的关键词，只在窗口内存里）、翻页状态（`PageReplacementPaging`）、
/// 原地刷新、加载 Task 与账户复核进度；不拥有收藏夹列表（`FavoriteFolderListModel`，构造时接管它的加载成功通知，用来回落
/// 已不存在的选择）。
///
/// 换夹、换排序、提交或清空关键词与翻页都整体替换：旧请求由 `LatestTask` 取消、迟到结果丢弃，每次替换成功
/// `successfulReloadGeneration` 前进，App 据此把网格滚回顶部。换夹时清空关键词、保留排序、回到第 1 页。工具栏刷新在已有
/// 内容时原地重读当前页：内容保持显示，成功后整体替换，失败保留内容并给出 `refreshError`。夹内读取报告收藏夹不存在时
/// 重新读取收藏夹列表，列表到达后按回落规则改选。
@MainActor
@Observable
public final class FavoriteFolderViewModel: AccountRevalidationParticipant {
    /// 选中的收藏夹（media_id），没有选择时为 nil；侧栏据此高亮对应的行。
    public private(set) var selectedFolderID: Int64?
    /// 排序菜单的选择；菜单选中后经 `selectOrder` 生效。
    public var orderSelection = FavoriteFolderOrder.recentlyFavorited
    /// 当前内容使用的排序。
    public private(set) var appliedOrder = FavoriteFolderOrder.recentlyFavorited
    /// 工具栏搜索框的文字；清空（只剩空白）且已按关键词过滤时恢复全部，提交前不影响内容（规则在
    /// `LibrarySearchKeyword`，与稍后再看共用）。
    public var searchDraft: String {
        get { keyword.draft }
        set {
            if keyword.updateDraft(newValue) {
                replaceContent()
            }
        }
    }
    /// 当前内容使用的关键词；空串表示不按关键词过滤。
    public var appliedKeyword: String {
        keyword.applied
    }
    /// 每次整体替换成功（含原地刷新）递增；App 只在它前进时把这个来源的网格滚回顶部。
    public private(set) var successfulReloadGeneration: UInt64 = 0
    /// 已有内容时的原地刷新正在进行。
    public private(set) var isRefreshing = false
    /// 最近一次原地刷新失败的原因，内容仍是刷新前的；下一次请求开始时清除。
    public private(set) var refreshError: ContentApplicationError?

    /// 读取发现凭据缺失或失效时递增；规则在共用的 `LibraryAccountRevalidation`。
    public var authenticationRevalidationGeneration: Int {
        revalidation.generation
    }

    /// 本页请求的账户复核尚未结束；失败页据此显示“正在重新确认”。
    public var isAwaitingAuthenticationRevalidation: Bool {
        revalidation.isAwaiting
    }

    /// 选中的收藏夹在列表里的元数据（标题、私密）；列表还没到或已不含它时为 nil。
    public var selectedFolder: FavoriteFolder? {
        guard let selectedFolderID else { return nil }
        return folderList.folders.first { $0.id == selectedFolderID }
    }

    /// 选中的收藏夹名称，App 用作导航标题；列表还没到或已不含它时为 nil。
    public var selectedFolderTitle: String? {
        selectedFolder?.title
    }

    /// 当前条件下的总条数（有关键词时是过滤后的条数）；翻页加载与失败期间保留，换夹或换条件后、第一页到达前为 nil。
    public var totalCount: Int? {
        paging.totalCount
    }

    /// 有关键词在起作用；结果为空时界面据此给出“清除搜索”。
    public var narrowsResults: Bool {
        !appliedKeyword.isEmpty
    }

    /// 当前请求、显示或失败的页与内容。
    package var phase: PageReplacementPaging<FavoriteFolderPage>.Phase {
        paging.phase
    }

    package var currentPage: Int {
        paging.currentPage
    }

    package var pageCount: Int {
        paging.pageCount
    }

    /// 工具栏刷新按钮是否禁用：正在读取；没有选中收藏夹时刷新重读收藏夹列表，列表正在读或账户 mid 未知（读不了）时禁用。
    public var isBusy: Bool {
        guard selectedFolderID != nil else {
            switch folderList.state {
            case .loading, .accountUnidentified:
                return true
            case .idle, .loaded, .failed:
                return folderList.isRefreshing
            }
        }
        if isRefreshing { return true }
        if case .loading = paging.phase { return true }
        return false
    }

    let folderList: FavoriteFolderListModel
    private var paging = PageReplacementPaging<FavoriteFolderPage>()
    private var keyword = LibrarySearchKeyword()
    private var revalidation = LibraryAccountRevalidation()
    @ObservationIgnored private let useCase: FavoritesUseCase
    /// 刷新、翻页与换条件共用的最新意图 Task；`reset` 与 `deactivateRoute` 取消。
    @ObservationIgnored private let loadTask = LatestTask()
    /// 收藏夹页面正在显示：`activate()` 置位，`deactivateRoute()` 清除。
    ///
    /// 只有显示时才因列表变化而加载新的选择。
    @ObservationIgnored private var isRouteActive = false
    /// 离开页面打断了加载、或留下了凭据失败页：回来时（`activate()`）重新读取当前页。
    @ObservationIgnored private var needsReloadOnActivation = false

    public init(useCase: FavoritesUseCase, folderList: FavoriteFolderListModel) {
        self.useCase = useCase
        self.folderList = folderList
        folderList.onFoldersLoaded = { [weak self] in self?.folderListDidLoad($0) }
    }

    /// 收藏夹页面出现或选中的收藏夹变化时由页面调用：标记正在显示；没有内容时加载当前页，还没有选择时选默认收藏夹。
    public func activate() {
        isRouteActive = true
        guard selectedFolderID != nil else {
            selectFallback(in: folderList.folders)
            return
        }
        if paging.phase == .idle || needsReloadOnActivation {
            load(page: paging.currentPage)
        }
    }

    /// 侧栏选中一个收藏夹：换夹时取消在途请求、清空关键词、保留排序，从第 1 页整体替换；选中同一个收藏夹时只重试失败。
    public func selectFolder(_ folderID: Int64) {
        guard folderID != selectedFolderID else {
            if case .failed = paging.phase { load(page: paging.currentPage) }
            return
        }
        selectedFolderID = folderID
        _ = keyword.clear()
        replaceContent()
    }

    /// 页码条翻页；越界、正在显示或正在加载的页不请求，失败的页可以再次请求。
    public func showPage(_ page: Int) {
        guard selectedFolderID != nil, paging.accepts(page) else { return }
        load(page: page)
    }

    /// 排序菜单已把 `orderSelection` 设为 `order`。
    public func selectOrder(_ order: FavoriteFolderOrder) {
        guard order != appliedOrder else { return }
        appliedOrder = order
        replaceContent()
    }

    /// 提交规范化后的草稿作为关键词；与已应用的关键词相同时不重新加载。
    public func submitSearch() {
        guard keyword.submit() else { return }
        replaceContent()
    }

    /// 无结果空态的“清除搜索”：清空关键词与草稿并重新加载，保留排序。
    public func clearSearch() {
        guard keyword.clear() else { return }
        replaceContent()
    }

    /// 工具栏刷新与失败重试：已显示条目时原地重读当前页，否则重新读取当前页；没有选中收藏夹时重读收藏夹列表。
    public func reload() {
        guard selectedFolderID != nil else {
            folderList.reload()
            return
        }
        // 本页没有条目时三种空态都不显示网格与刷新胶囊：完整重读（骨架或失败页），否则刷新既看不到进度、失败也被吞掉。
        guard case .loaded(_, let content) = paging.phase, !content.items.isEmpty else {
            load(page: paging.currentPage)
            return
        }
        refreshError = nil
        isRefreshing = true
        paging.beginRefresh()
        request(page: paging.currentPage, refreshing: true)
    }

    /// 离开收藏夹来源：取消请求，停止等待复核；被打断的加载与凭据失败页在回来时重新读取，已显示的内容保留。
    public func deactivateRoute() {
        isRouteActive = false
        loadTask.cancel()
        revalidation.stopAwaiting()
        isRefreshing = false
        refreshError = nil
        switch paging.phase {
        case .loading:
            needsReloadOnActivation = true
        case .failed(_, let failure) where LibraryAccountRevalidation.isCredentialFailure(failure):
            needsReloadOnActivation = true
        case .idle, .loaded, .failed:
            break
        }
    }

    /// 窗口的账户范围变化（登出、换号）：丢弃上一账户的选择、条件与内容。
    ///
    /// 仍在本页且已登录时，收藏夹列表重新到达后选中新账户的默认收藏夹。
    public func synchronizeAuthenticationSession() {
        reset()
    }

    /// 取消请求并从内存删除选择、条件与内容，供登出、换号与关窗调用；复核代次保留。
    public func reset() {
        discardContent()
        selectedFolderID = nil
        orderSelection = .recentlyFavorited
        appliedOrder = .recentlyFavorited
        keyword = LibrarySearchKeyword()
        revalidation.reset()
    }

    public func waitForCurrentTask() async {
        await loadTask.wait()
    }

    /// 账户复核确认仍已登录（窗口只在收藏夹是当前来源时调用）：本页请求的复核在本会话内自动重读一次当前页，其余情况只在
    /// 还没有内容时加载。
    public func authenticationRevalidationSucceeded() {
        guard selectedFolderID != nil else { return }
        if revalidation.succeeded() || paging.phase == .idle {
            load(page: paging.currentPage)
        }
    }

    /// 账户复核没能确认登录状态（窗口只在收藏夹是当前来源时调用）：给出可重试的“无法读取登录状态”。
    public func authenticationRevalidationFailed() {
        let requestedRevalidation = revalidation.failed()
        guard selectedFolderID != nil else { return }
        switch paging.phase {
        case .idle:
            paging.fail(page: paging.currentPage, error: .authenticationUnavailable)
        case .failed(let page, _) where requestedRevalidation:
            paging.fail(page: page, error: .authenticationUnavailable)
        case .loading, .loaded, .failed:
            break
        }
    }

    /// 条件或收藏夹变了：丢弃旧内容与总数，从第 1 页重新读取。
    private func replaceContent() {
        paging.reset()
        load(page: 1)
    }

    private func load(page: Int) {
        guard selectedFolderID != nil else { return }
        isRefreshing = false
        refreshError = nil
        needsReloadOnActivation = false
        paging.beginLoading(page: page)
        request(page: page, refreshing: false)
    }

    /// 发出 `page` 的请求；翻页状态已转为加载这一页，或正在原地刷新。
    private func request(page: Int, refreshing: Bool) {
        guard let folderID = selectedFolderID else { return }
        let pageRequest = FavoriteFolderRequest(
            folderID: folderID,
            order: appliedOrder,
            keyword: appliedKeyword,
            page: page
        )
        let useCase = useCase
        loadTask.replace { [weak self] isCurrent in
            do {
                let result = try await useCase.page(pageRequest)
                guard let self, isCurrent() else { return }
                apply(result, page: page)
            } catch is CancellationError {
                // 本任务未被取消却收到取消：认证会话在请求途中切换。原地刷新保留内容，其余回到空闲，由账户范围变化或
                // 复核结果重新加载。
                guard let self, isCurrent() else { return }
                isRefreshing = false
                if !refreshing { paging.reset() }
            } catch {
                guard let self, isCurrent() else { return }
                fail(
                    error as? ContentApplicationError ?? .unavailable,
                    page: page,
                    refreshing: refreshing
                )
            }
        }
    }

    private func apply(_ result: FavoriteFolderPage, page: Int) {
        isRefreshing = false
        let outcome = paging.succeed(
            page: page,
            content: result,
            totalCount: result.totalCount,
            pageSize: result.pageSize,
            hasMore: result.hasMore
        )
        switch outcome {
        case .show:
            revalidation.loadSucceeded()
            successfulReloadGeneration &+= 1
        case .request(let target):
            // 请求的页已越界（总数在翻页期间变少）：`paging` 改请求最后一页，或先回第 1 页取得新总数。
            request(page: target, refreshing: false)
        }
    }

    private func fail(_ failure: ContentApplicationError, page: Int, refreshing: Bool) {
        isRefreshing = false
        if failure == .contentUnavailable {
            // 收藏夹已不存在（被删除或不属于当前账户）：原地刷新也不再保留旧内容；重读列表，到达后按回落规则改选。
            paging.fail(page: page, error: failure)
            folderList.reload()
            return
        }
        let isCredentialFailure = LibraryAccountRevalidation.isCredentialFailure(failure)
        // 原地刷新失败保留已显示内容；凭据失败不再显示该账户的内容。
        if refreshing, !isCredentialFailure {
            refreshError = failure
            return
        }
        if isCredentialFailure {
            revalidation.request()
        }
        paging.fail(page: page, error: failure)
    }

    /// 收藏夹列表加载成功：选中的收藏夹已不在列表里就回落；还没有选择而页面正在显示（例如换号后）就选默认收藏夹。
    private func folderListDidLoad(_ folders: [FavoriteFolder]) {
        if let selectedFolderID, folders.contains(where: { $0.id == selectedFolderID }) {
            return
        }
        guard selectedFolderID != nil || isRouteActive else { return }
        selectFallback(in: folders)
    }

    /// 回落到默认收藏夹（按标记识别，不靠位置），没有默认收藏夹时取第一个；不在本页时只改选择，回来时再加载。
    private func selectFallback(in folders: [FavoriteFolder]) {
        guard let fallback = folders.first(where: \.isDefault) ?? folders.first else { return }
        if isRouteActive {
            selectFolder(fallback.id)
        } else {
            // 不在本页：取消旧收藏夹的在途请求、丢弃它的内容，只改选择，回来时再加载。
            discardContent()
            selectedFolderID = fallback.id
            _ = keyword.clear()
        }
    }

    /// 取消在途请求并丢弃当前内容与刷新状态（`reset` 与不在本页时的回落共用）；选择与条件由调用方处理。
    private func discardContent() {
        loadTask.cancel()
        paging.reset()
        isRefreshing = false
        refreshError = nil
        needsReloadOnActivation = false
    }
}
