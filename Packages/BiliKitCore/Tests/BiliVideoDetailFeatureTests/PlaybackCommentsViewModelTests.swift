import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

@Suite(.timeLimit(.minutes(1)))
struct PlaybackCommentsViewModelTests {
    @Test
    @MainActor
    func stableContinuationCanAppendMultiplePagesUntilTheServerEnds() async {
        let continuation = CommentContinuation(rawValue: "stable-session")
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(2)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(3)],
                    totalCount: 3,
                    continuation: continuation,
                    isEnd: true
                )
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2])
        #expect(!model.reachedEnd)
        #expect(model.paginationTermination == nil)

        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2, 3])
        #expect(model.reachedEnd)
        #expect(model.paginationTermination == .serverEnd)
    }

    @Test
    @MainActor
    func duplicatePageStopsAutomaticPagingAndExplicitRetryUsesTheSameContinuation() async {
        let continuation = CommentContinuation(rawValue: "stable-session")
        let repository = CommentRepositoryStub(
            rootPages: [
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 2,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(1)],
                    totalCount: 2,
                    continuation: continuation,
                    isEnd: false
                ),
                CommentRootPage(
                    threads: [thread(2)],
                    totalCount: 2,
                    continuation: nil,
                    isEnd: true
                )
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.loadNextPage()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1])
        #expect(!model.reachedEnd)
        #expect(model.paginationTermination == .duplicatePage)

        model.loadNextPage()
        await model.waitForCurrentRootTask()
        #expect(await repository.rootRequestCount == 2)

        model.retryRoot()
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [1, 2])
        #expect(model.paginationTermination == .serverEnd)
        #expect(await repository.rootRequestCount == 3)
    }

    @Test
    @MainActor
    func sameSubjectKeepsWorksetWhileNewSubjectReplacesIt() async {
        let repository = CommentRepositoryStub(
            rootPages: [
                endPage([thread(1)]),
                endPage([thread(2)])
            ]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )
        let firstSubject = CommentSubjectIdentity.video(aid: 700_001)

        model.activate(subject: firstSubject)
        await model.waitForCurrentRootTask()
        model.activate(subject: firstSubject)
        await model.waitForCurrentRootTask()
        #expect(await repository.rootRequestCount == 1)

        model.activate(subject: .video(aid: 700_002))
        await model.waitForCurrentRootTask()

        #expect(model.threads.map(\.id.rawValue) == [2])
        #expect(await repository.rootRequestCount == 2)
    }

    @Test
    @MainActor
    func sortReplacementRejectsLateOldResult() async throws {
        let repository = CommentRepositoryStub(holdsRoots: true)
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await repository.waitForRootRequestCount(1)

        model.selectSort(.latest)
        await repository.waitForRootRequestCount(2)
        await repository.releaseRoot(1, page: endPage([thread(2)]))
        await model.waitForCurrentRootTask()
        await repository.releaseRoot(0, page: endPage([thread(1)]))

        #expect(model.sort == .latest)
        #expect(model.threads.map(\.id.rawValue) == [2])
    }

    @Test
    @MainActor
    func collapsingThreadCancelsItsLateReplyReplacement() async throws {
        let rootID = CommentID(rawValue: 10)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(10)])],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await repository.waitForReplyRequestCount(1)

        model.collapseReplies(for: rootID)
        let collapsed = try #require(model.replyStates[rootID])
        #expect(!collapsed.isExpanded)
        #expect(!collapsed.isLoading)

        await repository.releaseReply(at: 0)
        // 同一根评论的新请求要等旧请求让出请求位才会发出，第二个请求出现即证明迟到回复已处理完。
        model.expandReplies(for: rootID)
        await repository.waitForReplyRequestCount(2)
        #expect(model.replyStates[rootID]?.replies.isEmpty == true)

        await repository.releaseReply(at: 1)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }
        #expect(model.replyStates[rootID]?.replies.map(\.id.rawValue) == [1001])
    }

    @Test
    @MainActor
    func replyPagerJumpsDirectlyButNotPastTheEndOrToTheSamePage() async {
        let rootID = CommentID(rawValue: 21)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(21)])],
            replyTotalCount: 25
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }

        model.showReplyPage(3, for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.pageNumber == 3 }
        #expect(model.replyStates[rootID]?.isEnd == true)

        model.showReplyPage(4, for: rootID)
        model.showReplyPage(3, for: rootID)
        model.showReplyPage(0, for: rootID)
        #expect(await repository.requestedReplyPages == [1, 3])

        model.showReplyPage(1, for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.pageNumber == 1 }
        #expect(await repository.requestedReplyPages == [1, 3, 1])
    }

    @Test
    @MainActor
    func failedReplyPageCannotBeSkippedAndRetryRequestsSamePage() async throws {
        let rootID = CommentID(rawValue: 20)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(20)])],
            replyTotalCount: 25,
            failingReplyPagesOnce: [2]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }

        model.showReplyPage(2, for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }
        #expect(model.replyStates[rootID]?.error == .transportFailure)

        model.showReplyPage(2, for: rootID)
        #expect(await repository.requestedReplyPages == [1, 2])

        model.retryReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }
        #expect(await repository.requestedReplyPages == [1, 2, 2])
        #expect(model.replyStates[rootID]?.error == nil)
    }

    @Test
    @MainActor
    func rootRetentionStopsAtTheInMemoryLimit() async {
        let repository = CommentRepositoryStub(
            rootPages: [endPage((1...1_001).map { thread(Int64($0)) })]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()

        #expect(model.threads.count == 1_000)
        #expect(model.reachedMemoryLimit)
        #expect(model.reachedEnd)
    }

    @Test
    @MainActor
    func collapsingPendingNextPageKeepsTheLastSuccessfulReplyPage() async throws {
        let rootID = CommentID(rawValue: 30)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(30)])],
            replyTotalCount: 11,
            heldReplyPages: [2]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }
        model.showReplyPage(2, for: rootID)
        await repository.waitForReplyRequestCount(2)

        model.collapseReplies(for: rootID)
        await repository.releaseReply(at: 1)
        model.expandReplies(for: rootID)

        let state = try #require(model.replyStates[rootID])
        #expect(state.pageNumber == 1)
        #expect(state.requestedPageNumber == nil)
        #expect(state.replies.map(\.id.rawValue) == [3001])
        #expect(await repository.requestedReplyPages == [1, 2])
    }

    @Test
    @MainActor
    func replyRequestsUseBoundedWindowConcurrency() async {
        let roots = (1...6).map { thread(Int64($0)) }
        let repository = CommentRepositoryStub(
            rootPages: [endPage(roots)],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        for root in roots {
            model.expandReplies(for: root.id)
        }
        await repository.waitForReplyRequestCount(4)

        // 折叠不会提前释放仍在途的请求位；重新展开排到队尾。
        model.collapseReplies(for: roots[0].id)
        model.expandReplies(for: roots[0].id)
        await repository.releaseReplies(rootID: roots[0].id)
        await repository.waitForReplyRequestCount(5)
        await repository.releaseAllHeldReplies()
        await repository.waitForReplyRequestCount(7)
        await repository.releaseAllHeldReplies()

        #expect(await repository.maximumActiveReplyCount == 4)
        #expect(await repository.replyRequestCount == 7)
    }

    @Test
    @MainActor
    func subjectReplacementRejectsLateReplyWithReusedRootID() async throws {
        let root = thread(50)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([root])],
            heldReplyPages: [1]
        )
        let model = PlaybackCommentsViewModel(
            useCase: CommentUseCase(repository: repository)
        )

        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: root.id)
        await repository.waitForReplyRequestCount(1)

        model.activate(subject: .video(aid: 700_002))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: root.id)

        await repository.releaseReply(at: 0, replyID: 51)
        await repository.waitForReplyRequestCount(2)
        await repository.releaseReply(at: 1, replyID: 52)
        await waitForObservedState { model.replyStates[root.id]?.isLoading == false }

        let state = try #require(model.replyStates[root.id])
        #expect(state.replies.map(\.id.rawValue) == [52])
        #expect(await repository.replyRequestCount == 2)
    }

    @Test
    @MainActor
    func rootAndReplyAuthenticationInvalidationPublishRevalidationIntent() async throws {
        let rootFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: CommentRepositoryStub(rootFailure: .authenticationInvalid)
            )
        )
        rootFailureModel.activate(subject: .video(aid: 700_001))
        await rootFailureModel.waitForCurrentRootTask()

        #expect(rootFailureModel.rootState == .failed(.authenticationInvalid))
        #expect(rootFailureModel.authenticationRevalidationGeneration == 1)

        let root = thread(80)
        let replyFailureModel = PlaybackCommentsViewModel(
            useCase: CommentUseCase(
                repository: CommentRepositoryStub(
                    rootPages: [endPage([root])],
                    replyFailure: .authenticationInvalid
                )
            )
        )
        replyFailureModel.activate(subject: .video(aid: 700_001))
        await replyFailureModel.waitForCurrentRootTask()
        replyFailureModel.expandReplies(for: root.id)
        await waitForObservedState {
            replyFailureModel.replyStates[root.id]?.isLoading == false
        }

        #expect(
            replyFailureModel.replyStates[root.id]?.error
                == .authenticationInvalid
        )
        #expect(replyFailureModel.authenticationRevalidationGeneration == 1)
    }

    /// 查看对话只对回复别人的回复生效，按楼层往下加载到底后不再请求；关掉对话回到原页，页码与回复不变。
    @Test
    @MainActor
    func dialogLoadsByFloorUntilTheEndAndClosingReturnsToTheSamePage() async {
        let rootID = CommentID(rawValue: 40)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(40)])],
            replyTotalCount: 25
        )
        let model = PlaybackCommentsViewModel(useCase: CommentUseCase(repository: repository))
        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }
        let pageReplies = model.replyStates[rootID]?.replies

        model.showDialog(of: reply(41, root: 40, parent: 40, dialog: 41), for: rootID)
        #expect(model.replyStates[rootID]?.dialog == nil)

        model.showDialog(of: reply(43, root: 40, parent: 42, dialog: 41), for: rootID)
        await waitForObservedState {
            model.replyStates[rootID]?.dialog?.hasLoadedFirstPage == true
        }
        #expect(model.replyStates[rootID]?.dialog?.replies.map(\.id.rawValue) == [40_001, 40_002])
        #expect(model.replyStates[rootID]?.dialog?.isEnd == false)

        model.loadMoreDialog(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.dialog?.isEnd == true }
        #expect(
            model.replyStates[rootID]?.dialog?.replies.map(\.id.rawValue)
                == [40_001, 40_002, 40_003]
        )
        model.loadMoreDialog(for: rootID)
        #expect(await repository.dialogRequests == [nil, 3])

        model.closeDialog(for: rootID)
        #expect(model.replyStates[rootID]?.dialog == nil)
        #expect(model.replyStates[rootID]?.pageNumber == 1)
        #expect(model.replyStates[rootID]?.replies == pageReplies)
    }

    /// 关掉对话或收起后，在途的对话请求结果不再写回；之后楼中楼照常翻页。
    @Test
    @MainActor
    func closingTheDialogDiscardsItsInFlightPage() async {
        let rootID = CommentID(rawValue: 50)
        let repository = CommentRepositoryStub(
            rootPages: [endPage([thread(50)])],
            replyTotalCount: 25,
            holdsDialogs: true
        )
        let model = PlaybackCommentsViewModel(useCase: CommentUseCase(repository: repository))
        model.activate(subject: .video(aid: 700_001))
        await model.waitForCurrentRootTask()
        model.expandReplies(for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.isLoading == false }

        model.showDialog(of: reply(53, root: 50, parent: 52, dialog: 51), for: rootID)
        await repository.waitForDialogRequestCount(1)
        model.closeDialog(for: rootID)
        await repository.releaseDialogs()
        model.showReplyPage(2, for: rootID)
        await waitForObservedState { model.replyStates[rootID]?.pageNumber == 2 }

        #expect(model.replyStates[rootID]?.dialog == nil)
        #expect(await repository.requestedReplyPages == [1, 2])
    }
}

private func reply(_ id: Int64, root: Int64, parent: Int64, dialog: Int64) -> BiliModels.Comment {
    BiliModels.Comment(
        id: CommentID(rawValue: id),
        rootID: CommentID(rawValue: root),
        parentID: CommentID(rawValue: parent),
        dialogID: CommentID(rawValue: dialog),
        payload: .unavailable(.unavailable)
    )
}

private func endPage(_ threads: [CommentThread]) -> CommentRootPage {
    CommentRootPage(
        threads: threads,
        totalCount: threads.count,
        continuation: nil,
        isEnd: true
    )
}

private func thread(_ id: Int64) -> CommentThread {
    CommentThread(root: comment(id))
}

private func comment(_ id: Int64) -> BiliModels.Comment {
    BiliModels.Comment(
        id: CommentID(rawValue: id),
        payload: .unavailable(.unavailable)
    )
}
