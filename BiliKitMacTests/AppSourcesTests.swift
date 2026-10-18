import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import Testing

@testable import BiliKit

/// 每个来源恰好一份描述，侧栏按固定的组顺序分段、组内按 case 顺序排列；只有观看历史要求账户，离开、换号与关窗的
/// 停用与清理经描述作用到来源的模型。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AppSourcesTests {
    @Test
    func everySourceHasOneDescriptorInSidebarOrder() {
        let sources = makeSources()

        #expect(Set(sources.ordered.map(\.id)) == Set(AppTab.allCases))
        #expect(sources.ordered.count == AppTab.allCases.count)
        for tab in AppTab.allCases {
            #expect(sources[tab].id == tab)
        }
        #expect(sources.ordered.filter(\.requiresAccount).map(\.id) == [.history])
    }

    /// 顶部无标题的一组是搜索、首页、热门，「资料库」组带标题；侧栏顺序就是各段依次展开。
    @Test
    func sidebarGroupsSourcesUnderFixedSections() {
        let sources = makeSources()

        #expect(sources.sections.map(\.group) == [.browse, .library])
        #expect(sources.sections.map { $0.sources.map(\.id) } == [[.search, .home, .popular], [.history]])
        #expect(sources.ordered.map(\.id) == sources.sections.flatMap { $0.sources.map(\.id) })
        #expect(AppSourceGroup.browse.title == nil)
        #expect(AppSourceGroup.library.title != nil)
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
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
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
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
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
            trendingSearchModel: TrendingSearchViewModel(
                useCase: TrendingSearchUseCase(repository: EmptyTrendingSearchRepository())
            )
        )
    }
}
