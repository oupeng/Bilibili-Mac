import BiliApplication
import BiliModels
import Foundation
import Observation

/// 评论 root 列表的整体状态；加载下一页的失败不改变它，单独记在 `paginationError`。
public enum PlaybackCommentsRootState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(CommentReadError)
}

/// 单条 root 评论的楼中楼展开、分页与失败状态，由 `PlaybackCommentsViewModel` 按 root ID 持有。
///
/// `dialog` 非 nil 时面板显示那串对话；当前页的回复与页码保留，关掉对话回到原页。
public struct PlaybackCommentReplyState: Sendable, Equatable {
    public var isExpanded = false
    public var replies: [BiliModels.Comment] = []
    public var pageNumber = 1
    public var requestedPageNumber: Int?
    public var totalCount = 0
    public var isLoading = false
    public var isEnd = false
    public var error: CommentReadError?
    public var dialog: PlaybackCommentDialogState?

    public init() {}

    /// 展开后列出的回复：看对话时是对话里已加载的回复，否则是当前页；面板、行高测量与时间戳判断共用。
    public var shownReplies: [BiliModels.Comment] {
        dialog?.replies ?? replies
    }
}

/// 楼中楼面板里正在查看的一串对话（「查看对话」）：按楼层往下加载，没有页码。
public struct PlaybackCommentDialogState: Sendable, Equatable {
    public let dialogID: CommentID
    public var replies: [BiliModels.Comment] = []
    /// 下一页的起点楼层；第一页到达之前与到底之后都为 nil，以 `hasLoadedFirstPage` 区分。
    public var nextFloor: Int?
    public var hasLoadedFirstPage = false
    public var isLoading = false
    public var error: CommentReadError?

    public init(dialogID: CommentID) {
        self.dialogID = dialogID
    }

    public var isEnd: Bool { hasLoadedFirstPage && nextFloor == nil }
}

/// 独立拥有当前视频评论的 root 与楼中楼状态，不拥有或控制播放器。
@MainActor
@Observable
public final class PlaybackCommentsViewModel: AccountRevalidationParticipant {
    /// 一楼要读的内容：楼中楼的某一页，或某串对话从某楼层起的一页。
    private enum ReplyRequestTarget: Equatable {
        case page(Int)
        case dialog(CommentID, fromFloor: Int?)
    }

    /// 楼中楼与对话请求共用一个队列：同一楼同时只有一个在途，`rootGeneration` 与 subject 拒绝旧结果。
    private struct PendingReplyRequest {
        let rootID: CommentID
        let target: ReplyRequestTarget
        let subject: CommentSubjectIdentity
        let rootGeneration: Int
    }

    private enum ReplyRequestResult {
        case page(CommentReplyBatch)
        case dialog(CommentDialogPage)
    }

    public private(set) var subject: CommentSubjectIdentity?
    public private(set) var sort: CommentSort = .hot
    public private(set) var rootState: PlaybackCommentsRootState = .idle
    public private(set) var threads: [CommentThread] = []
    public private(set) var totalCount = 0
    public private(set) var isLoadingNextPage = false
    public private(set) var paginationError: CommentReadError?
    public private(set) var paginationTermination: CommentPaginationTermination?
    public private(set) var reachedEnd = false
    public private(set) var reachedMemoryLimit = false
    public private(set) var replyStates: [CommentID: PlaybackCommentReplyState] = [:]
    /// 仅在确认评论凭据失效时递增，由 App 层协调账户重校验。
    public private(set) var authenticationRevalidationGeneration = 0

    @ObservationIgnored private let useCase: CommentUseCase
    @ObservationIgnored private let rootTask = LatestTask()
    @ObservationIgnored private var activeReplyTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeReplyRoots: [UUID: CommentID] = [:]
    @ObservationIgnored private var replyRequestIDs: [CommentID: UUID] = [:]
    @ObservationIgnored private var pendingReplyRequests: [PendingReplyRequest] = []
    @ObservationIgnored private var continuation: CommentContinuation?
    /// root 工作集身份；楼中楼请求以它拒绝跨 subject、排序或重载的旧结果。
    @ObservationIgnored private var rootGeneration = 0
    private static let maximumRetainedRootThreads = 1_000
    private static let maximumConcurrentReplyRequests = 4

    public init(useCase: CommentUseCase) {
        self.useCase = useCase
    }

    public func activateVideo(aid: Int64) {
        guard aid > 0 else {
            reset()
            return
        }
        activate(subject: .video(aid: aid))
    }

    deinit {
        for task in activeReplyTasks.values {
            task.cancel()
        }
    }

    public func activate(subject newSubject: CommentSubjectIdentity) {
        guard subject != newSubject else {
            if rootState == .idle {
                loadInitialPage()
            }
            return
        }
        replaceRootWorkset(subject: newSubject, sort: sort)
    }

    public func selectSort(_ newSort: CommentSort) {
        guard sort != newSort else { return }
        sort = newSort
        guard let subject else { return }
        replaceRootWorkset(subject: subject, sort: newSort)
    }

    public func loadNextPage() {
        guard subject != nil, !isLoadingNextPage, !reachedEnd,
            continuation != nil, paginationTermination == nil,
            rootState == .loaded
        else { return }
        loadRootPage(isInitial: false)
    }

    public func retryRoot() {
        switch rootState {
        case .failed:
            loadInitialPage()
        case .loaded where paginationError != nil:
            loadNextPage()
        case .loaded where paginationTermination != nil:
            paginationTermination = nil
            loadRootPage(isInitial: false)
        case .empty where paginationTermination != nil:
            loadInitialPage()
        case .idle, .loading, .loaded, .empty:
            break
        }
    }

    public func expandReplies(for rootID: CommentID) {
        guard threads.contains(where: { $0.id == rootID }) else { return }
        var state = replyStates[rootID] ?? PlaybackCommentReplyState()
        state.isExpanded = true
        replyStates[rootID] = state
        guard state.replies.isEmpty, !state.isLoading else { return }
        loadReplyPage(rootID: rootID, page: 1)
    }

    public func collapseReplies(for rootID: CommentID) {
        guard var state = replyStates[rootID] else { return }
        cancelReplyRequest(for: rootID)
        state.isExpanded = false
        state.isLoading = false
        state.error = nil
        state.requestedPageNumber = nil
        state.dialog = nil
        replyStates[rootID] = state
    }

    /// 在楼中楼面板里查看 `reply` 所在的那串对话：面板原地换成按楼层排列的对话，「返回全部回复」回到原页。
    ///
    /// 只对这一楼里回复别人的回复（`Comment.isReplyInDialog`）生效；面板未展开、这一页正在加载或已在看对话时不切换。
    public func showDialog(of reply: BiliModels.Comment, for rootID: CommentID) {
        guard var state = replyStates[rootID], state.isExpanded, !state.isLoading,
            state.dialog == nil, reply.rootID == rootID, reply.isReplyInDialog,
            let dialogID = reply.dialogID
        else { return }
        state.dialog = PlaybackCommentDialogState(dialogID: dialogID)
        replyStates[rootID] = state
        loadDialogPage(rootID: rootID)
    }

    /// 对话的下一页；上一次失败时按同一起点重试。
    ///
    /// 到底、正在加载或没有在看对话时不请求。
    public func loadMoreDialog(for rootID: CommentID) {
        guard let dialog = replyStates[rootID]?.dialog, !dialog.isLoading,
            dialog.error != nil || dialog.nextFloor != nil
        else { return }
        loadDialogPage(rootID: rootID)
    }

    /// 关掉对话回到楼中楼原页，在途的对话请求取消、结果不再写回。
    public func closeDialog(for rootID: CommentID) {
        guard var state = replyStates[rootID], state.dialog != nil else { return }
        cancelReplyRequest(for: rootID)
        state.dialog = nil
        replyStates[rootID] = state
    }

    /// 翻到楼中楼第 `page` 页：页码条的数字与前后箭头都经这里，接口按页码直接取页。
    ///
    /// 页码小于 1、等于当前页、在已知末页之后，或这一楼正停在失败待重试时不请求；页数上限由页码条按总条数夹住。
    public func showReplyPage(_ page: Int, for rootID: CommentID) {
        guard let state = replyStates[rootID], state.error == nil,
            page >= 1, page != state.pageNumber,
            page < state.pageNumber || !state.isEnd
        else { return }
        loadReplyPage(rootID: rootID, page: page)
    }

    public func retryReplies(for rootID: CommentID) {
        guard let state = replyStates[rootID], state.error != nil else {
            return
        }
        loadReplyPage(
            rootID: rootID,
            page: state.requestedPageNumber ?? state.pageNumber
        )
    }

    public func reset() {
        rootGeneration += 1
        rootTask.cancel()
        cancelAllReplyTasks()
        subject = nil
        rootState = .idle
        clearRootState()
    }

    public func waitForCurrentRootTask() async {
        await rootTask.wait()
    }

    private func replaceRootWorkset(
        subject newSubject: CommentSubjectIdentity,
        sort newSort: CommentSort
    ) {
        rootGeneration += 1
        rootTask.cancel()
        cancelAllReplyTasks()
        subject = newSubject
        sort = newSort
        rootState = .idle
        clearRootState()
        loadInitialPage()
    }

    private func loadInitialPage() {
        guard subject != nil else { return }
        rootGeneration += 1
        rootState = .loading
        clearRootState()
        loadRootPage(isInitial: true)
    }

    /// 清空 root 列表、分页与楼中楼展示状态；`rootState` 与请求取消由调用方决定。
    private func clearRootState() {
        threads = []
        totalCount = 0
        continuation = nil
        isLoadingNextPage = false
        paginationError = nil
        paginationTermination = nil
        reachedEnd = false
        reachedMemoryLimit = false
        replyStates = [:]
    }

    private func loadRootPage(isInitial: Bool) {
        guard let subject else { return }
        let requestedContinuation = continuation
        let requestedSort = sort
        let existingIDs = Set(threads.map(\.id))
        if !isInitial {
            isLoadingNextPage = true
            paginationError = nil
        }
        let useCase = self.useCase
        rootTask.replace { [weak self, useCase] isCurrent in
            do {
                let batch = try await useCase.loadRoots(
                    for: subject,
                    sort: requestedSort,
                    after: requestedContinuation,
                    excluding: existingIDs
                )
                try Task.checkCancellation()
                guard let self, isCurrent(), self.subject == subject else { return }
                appendRootBatch(batch)
            } catch is CancellationError {
                guard let self, isCurrent() else { return }
                if isInitial {
                    rootState = .idle
                }
                isLoadingNextPage = false
            } catch {
                guard let self, isCurrent() else { return }
                recordRootFailure(
                    error as? CommentReadError ?? .unavailable,
                    isInitial: isInitial
                )
            }
        }
    }

    private func appendRootBatch(_ batch: CommentRootBatch) {
        let remainingCapacity = max(
            0,
            Self.maximumRetainedRootThreads - threads.count
        )
        let droppedByMemoryLimit = batch.threads.count > remainingCapacity
        threads.append(contentsOf: batch.threads.prefix(remainingCapacity))
        totalCount = batch.totalCount
        reachedMemoryLimit =
            droppedByMemoryLimit
            || (threads.count == Self.maximumRetainedRootThreads
                && batch.termination == nil)
        continuation = reachedMemoryLimit ? nil : batch.continuation
        paginationTermination = batch.termination
        reachedEnd =
            batch.termination == .serverEnd || reachedMemoryLimit
        rootState = threads.isEmpty ? .empty : .loaded
        isLoadingNextPage = false
        paginationError = nil
    }

    private func recordRootFailure(
        _ error: CommentReadError,
        isInitial: Bool
    ) {
        recordAuthenticationInvalidationIfNeeded(error)
        isLoadingNextPage = false
        if isInitial {
            rootState = .failed(error)
        } else {
            paginationError = error
        }
    }

    private func loadReplyPage(rootID: CommentID, page: Int) {
        guard let subject, var state = replyStates[rootID], state.isExpanded,
            !state.isLoading, state.dialog == nil
        else { return }
        state.requestedPageNumber = page
        state.isLoading = true
        state.error = nil
        replyStates[rootID] = state
        enqueueReplyRequest(rootID: rootID, target: .page(page), subject: subject)
    }

    /// 对话从 `nextFloor` 起的一页（第一页时为 nil）；失败后重试沿用同一起点。
    private func loadDialogPage(rootID: CommentID) {
        guard let subject, var state = replyStates[rootID], state.isExpanded,
            var dialog = state.dialog, !dialog.isLoading
        else { return }
        dialog.isLoading = true
        dialog.error = nil
        state.dialog = dialog
        replyStates[rootID] = state
        enqueueReplyRequest(
            rootID: rootID,
            target: .dialog(dialog.dialogID, fromFloor: dialog.nextFloor),
            subject: subject
        )
    }

    private func enqueueReplyRequest(
        rootID: CommentID,
        target: ReplyRequestTarget,
        subject: CommentSubjectIdentity
    ) {
        pendingReplyRequests.append(
            PendingReplyRequest(
                rootID: rootID,
                target: target,
                subject: subject,
                rootGeneration: rootGeneration
            )
        )
        startPendingReplyRequests()
    }

    /// 这一楼排队中与在途的请求都作废；在途 Task 取消，回来的结果按请求 ID 不再写回。
    private func cancelReplyRequest(for rootID: CommentID) {
        pendingReplyRequests.removeAll { $0.rootID == rootID }
        if let requestID = replyRequestIDs.removeValue(forKey: rootID) {
            activeReplyTasks[requestID]?.cancel()
        }
    }

    /// 排队期间这一楼的状态变了（收起、换页、关掉对话）就不再发出。
    private func isStillWanted(_ request: PendingReplyRequest) -> Bool {
        guard let state = replyStates[request.rootID], state.isExpanded else { return false }
        switch request.target {
        case .page(let page):
            return state.dialog == nil && state.isLoading && state.requestedPageNumber == page
        case .dialog(let dialogID, let fromFloor):
            guard let dialog = state.dialog else { return false }
            return dialog.dialogID == dialogID && dialog.isLoading && dialog.nextFloor == fromFloor
        }
    }

    private func startPendingReplyRequests() {
        while activeReplyTasks.count < Self.maximumConcurrentReplyRequests,
            !pendingReplyRequests.isEmpty
        {
            let activeRoots = Set(activeReplyRoots.values)
            guard
                let index = pendingReplyRequests.firstIndex(where: { request in
                    !activeRoots.contains(request.rootID)
                })
            else { return }
            let request = pendingReplyRequests.remove(at: index)
            guard rootGeneration == request.rootGeneration,
                subject == request.subject,
                replyRequestIDs[request.rootID] == nil,
                isStillWanted(request)
            else { continue }
            startReplyRequest(request)
        }
    }

    private func startReplyRequest(_ request: PendingReplyRequest) {
        let requestID = UUID()
        replyRequestIDs[request.rootID] = requestID
        activeReplyRoots[requestID] = request.rootID
        let useCase = self.useCase
        activeReplyTasks[requestID] = Task { [weak self, useCase] in
            defer {
                self?.finishReplyRequest(
                    rootID: request.rootID,
                    requestID: requestID
                )
            }
            let result: ReplyRequestResult
            do {
                switch request.target {
                case .page(let page):
                    result = .page(
                        try await useCase.loadReplies(
                            for: request.subject,
                            rootID: request.rootID,
                            page: page
                        )
                    )
                case .dialog(let dialogID, let fromFloor):
                    result = .dialog(
                        try await useCase.loadDialog(
                            for: request.subject,
                            rootID: request.rootID,
                            dialogID: dialogID,
                            fromFloor: fromFloor
                        )
                    )
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                self?.endReplyRequest(request, requestID: requestID, error: nil)
                return
            } catch {
                self?.endReplyRequest(
                    request,
                    requestID: requestID,
                    error: error as? CommentReadError ?? .unavailable
                )
                return
            }
            self?.applyReplyResult(result, of: request, requestID: requestID)
        }
    }

    private func applyReplyResult(
        _ result: ReplyRequestResult,
        of request: PendingReplyRequest,
        requestID: UUID
    ) {
        guard replyRequestIDs[request.rootID] == requestID,
            rootGeneration == request.rootGeneration,
            subject == request.subject,
            var current = replyStates[request.rootID], current.isExpanded
        else { return }
        switch result {
        case .page(let batch):
            current.replies = batch.replies
            current.pageNumber = batch.pageNumber
            current.requestedPageNumber = nil
            current.totalCount = batch.totalCount
            current.isEnd = batch.isEnd
            current.isLoading = false
            current.error = nil
        case .dialog(let page):
            guard var dialog = current.dialog, dialog.dialogID == page.dialogID else { return }
            let shown = Set(dialog.replies.map(\.id))
            dialog.replies += page.replies.filter { !shown.contains($0.id) }
            dialog.nextFloor = page.nextFloor
            dialog.hasLoadedFirstPage = true
            dialog.isLoading = false
            dialog.error = nil
            current.dialog = dialog
        }
        replyStates[request.rootID] = current
    }

    /// 请求以失败（`error` 非 nil）或取消（nil）结束：只结束对应的加载状态；取消不记错误。
    private func endReplyRequest(
        _ request: PendingReplyRequest,
        requestID: UUID,
        error: CommentReadError?
    ) {
        guard replyRequestIDs[request.rootID] == requestID,
            var current = replyStates[request.rootID]
        else { return }
        if error != nil {
            guard rootGeneration == request.rootGeneration, subject == request.subject else {
                return
            }
        }
        if let error { recordAuthenticationInvalidationIfNeeded(error) }
        switch request.target {
        case .page:
            current.isLoading = false
            if let error { current.error = error }
        case .dialog(let dialogID, _):
            guard var dialog = current.dialog, dialog.dialogID == dialogID else { return }
            dialog.isLoading = false
            if let error { dialog.error = error }
            current.dialog = dialog
        }
        replyStates[request.rootID] = current
    }

    private func finishReplyRequest(rootID: CommentID, requestID: UUID) {
        activeReplyTasks[requestID] = nil
        activeReplyRoots[requestID] = nil
        if replyRequestIDs[rootID] == requestID {
            replyRequestIDs[rootID] = nil
        }
        startPendingReplyRequests()
    }

    private func recordAuthenticationInvalidationIfNeeded(
        _ error: CommentReadError
    ) {
        guard error.requiresAccountRevalidation else { return }
        authenticationRevalidationGeneration &+= 1
    }

    private func cancelAllReplyTasks() {
        for task in activeReplyTasks.values {
            task.cancel()
        }
        replyRequestIDs = [:]
        pendingReplyRequests = []
    }
}
