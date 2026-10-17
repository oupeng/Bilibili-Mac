import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 原地刷新：刷新期间保留已显示内容并收起分页尾标，只有成功的刷新推进本来源的代次，迟到的旧追加被丢弃。
@Suite(.timeLimit(.minutes(1)))
struct FeedRefreshTests {
    @Test(.timeLimit(.minutes(1)))
    @MainActor
    func popularRefreshCancelsAndRejectsLateAppend() async throws {
        let old = ContentFixtures(bvid: "BV1PopularF6", title: "旧热门榜单")
        let fresh = ContentFixtures(bvid: "BV1PopularG7", title: "刷新热门榜单")
        let appendGate = TestGate()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if request.page == 2 {
                await appendGate.pass()
                return old.popularPage(request)
            }
            return (attempt == 1 ? old : fresh).popularPage(
                request,
                hasMore: attempt == 1
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        try await appendGate.waitForEntries()

        model.refreshPopular(pageSize: 50)
        try await appendGate.waitForCancellations()
        await model.waitForCurrentTask()
        await appendGate.open()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("刷新后的热门榜单应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fresh.bvid])
        #expect(page.pageNumber == 1)
        #expect(!page.hasMore)
        #expect(model.successfulRefreshGeneration(for: .popular) == 1)
    }

    @Test
    @MainActor
    func failedRefreshKeepsMatchingLoadedContentVisible() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if attempt == 2 { throw ContentApplicationError.requestRestricted }
            return fixture.popularPage(request)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedState = model.state
        let successfulRefreshGeneration =
            model.successfulRefreshGeneration(for: .popular)

        model.refreshPopular(pageSize: 50)
        #expect(model.state == loadedState)
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.state == loadedState)
        #expect(!model.isRefreshing)
        #expect(model.refreshError == .requestRestricted)
        #expect(
            model.successfulRefreshGeneration(for: .popular)
                == successfulRefreshGeneration
        )
        #expect(await repository.popularPages.count == 2)
    }

    @Test
    @MainActor
    func inPlaceRefreshWithdrawsPaginationTailUntilItSettles() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(popular: { request, attempt in
            if attempt == 2 { throw ContentApplicationError.requestRestricted }
            return fixture.popularPage(request, hasMore: true)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )
        let request = FeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        let loadedPagination = model.pagination(for: request)

        model.refreshPopular(pageSize: 50)
        let refreshingPagination = model.pagination(for: request)
        await model.waitForCurrentTask()

        #expect(loadedPagination.canLoadMore)
        #expect(loadedPagination.tailIdentity != nil)
        #expect(!refreshingPagination.canLoadMore)
        #expect(refreshingPagination.tailIdentity == nil)
        #expect(model.refreshError == .requestRestricted)
        #expect(model.pagination(for: request) == loadedPagination)
    }

    @Test
    @MainActor
    func onlySuccessfulSameQueryRefreshAdvancesSearchGeneration() async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(search: { request, attempt in
            if attempt == 3 { throw ContentApplicationError.requestRestricted }
            return fixture.searchPage(page: request.page)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.search(VideoSearchCriteria(query: "macOS"))
        await model.waitForCurrentTask()
        #expect(model.successfulRefreshGeneration(for: .search) == 0)

        model.search(VideoSearchCriteria(query: "macOS"))
        await model.waitForCurrentTask()
        #expect(model.successfulRefreshGeneration(for: .search) == 1)

        model.search(VideoSearchCriteria(query: "macOS"))
        #expect(model.isRefreshing)
        await model.waitForCurrentTask()

        #expect(model.successfulRefreshGeneration(for: .search) == 1)
        #expect(model.refreshError == .requestRestricted)
        #expect(await repository.searchRequests.count == 3)
    }

    @Test(arguments: [BrowseFeed.recommendation, .popular, .search])
    @MainActor
    func successfulRefreshAdvancesOnlyItsOwnSourceGeneration(_ feed: BrowseFeed) async {
        let fixture = ContentFixtures()
        let repository = FeedRepositoryStub(
            recommendations: { _, _ in fixture.recommendationPage },
            popular: { request, _ in fixture.popularPage(request) },
            search: { request, _ in fixture.searchPage(page: request.page) }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        feed.refresh(model)
        await model.waitForCurrentTask()

        for source in FeedSource.allCases {
            #expect(
                model.successfulRefreshGeneration(for: source)
                    == (source == feed.source ? 1 : 0)
            )
        }
    }
}
