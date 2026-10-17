import BiliApplication
import BiliBrowseFeature
import BiliLibraryFeature
import Testing

@testable import BiliKit

/// 每个来源恰好一份描述并按侧栏顺序排列；只有观看历史要求账户，离开、换号与关窗对它的停用与清理经描述生效。
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

    private func makeSources(
        historyModel: WatchHistoryViewModel = WatchHistoryViewModel(
            useCase: WatchHistoryUseCase(repository: WatchHistoryRepositoryStub())
        )
    ) -> AppSources {
        AppSources(
            browseModel: BrowseViewModel(useCase: FeedUseCase(repository: EmptyFeedRepository())),
            historyModel: historyModel,
            trendingSearchModel: nil
        )
    }
}
