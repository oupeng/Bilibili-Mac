import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import Testing

@testable import BiliKit

/// 每个来源恰好一份描述并按侧栏顺序排列；只有观看历史要求账户，离开、换号与关窗的停用与清理经描述作用到来源的模型。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppSourcesTests {
    @Test
    func everySourceHasOneDescriptorInSidebarOrder() {
        let sources = makeSources()

        #expect(sources.ordered.map(\.id) == AppTab.allCases)
        for tab in AppTab.allCases {
            #expect(sources[tab].id == tab)
        }
        #expect(sources.ordered.filter(\.requiresAccount).map(\.id) == [.history])
    }

    @Test
    func historyDescriptorFollowsItsModel() async {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        )
        let sources = makeSources(historyModel: historyModel)

        historyModel.loadIfNeeded()
        await historyModel.waitForCurrentTask()
        #expect(sources[.history].refreshGeneration() == 1)

        sources.resetAccountContent()
        #expect(historyModel.state == .idle)
    }

    @Test
    func leavingHistoryReturnsItsCredentialFailureToIdle() async {
        let historyModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(
                repository: WatchHistoryRepositoryStub(error: .authenticationRequired)
            )
        )
        let sources = makeSources(historyModel: historyModel)
        historyModel.loadIfNeeded()
        await historyModel.waitForCurrentTask()
        #expect(historyModel.state == .failed(.authenticationRequired))

        sources[.history].deactivate()

        #expect(historyModel.state == .idle)
    }

    /// 关窗时搜索来源清空草稿，撤回已提交的搜索。
    @Test
    func windowClosureClearsTheSearchSession() {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: EmptyFeedRepository()))
        let session = VideoSearchSession(browseModel: browseModel, recordHistory: { _ in })
        let sources = AppSources(
            browseModel: browseModel,
            historyModel: WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
            ),
            searchSession: session,
            trendingSearchModel: nil
        )
        session.search(keyword: "猫")

        sources.resetForWindowClosure()

        #expect(session.draft.isEmpty)
        #expect(session.submittedCriteria == nil)
    }

    /// 账户变化（本窗口换号或其他窗口换号）不动搜索草稿与已提交的搜索：搜索不要求账户，只有 Browse 工作集重启。
    @Test
    func accountChangeKeepsTheSearchDraft() {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: EmptyFeedRepository()))
        let session = VideoSearchSession(browseModel: browseModel, recordHistory: { _ in })
        let sources = AppSources(
            browseModel: browseModel,
            historyModel: WatchHistoryViewModel(
                useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
            ),
            searchSession: session,
            trendingSearchModel: nil
        )
        session.search(keyword: "猫")
        let submitted = session.submittedCriteria

        sources.resetAccountContent()
        for source in sources.ordered {
            source.synchronizeAccountSession(
                AccountSessionChange(
                    generation: 1,
                    scope: .signedIn(accountID: 2),
                    isCurrentRoute: source.id == .search
                )
            )
        }

        #expect(session.draft == "猫")
        #expect(session.submittedCriteria == submitted)
    }

    private func makeSources(
        historyModel: WatchHistoryViewModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        )
    ) -> AppSources {
        let browseModel = BrowseViewModel(useCase: FeedUseCase(repository: EmptyFeedRepository()))
        return AppSources(
            browseModel: browseModel,
            historyModel: historyModel,
            searchSession: VideoSearchSession(browseModel: browseModel, recordHistory: { _ in }),
            trendingSearchModel: nil
        )
    }
}
