import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// Feed 的凭据失效请求窗口复核（追加失败保留卡片）；账户代次变化重启当前来源并丢弃旧账户的迟到结果。
@Suite(.timeLimit(.minutes(1)))
struct FeedAuthenticationTests {
    @Test
    @MainActor
    func recommendationAuthenticationFailureRequestsRevalidation() async {
        let repository = FeedRepositoryStub(recommendations: { _, _ in
            throw ContentApplicationError.authenticationInvalid
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()

        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(
            model.state
                == .failed(
                    request: .recommendation(continuation: nil),
                    error: .authenticationInvalid
                )
        )
    }

    @Test
    @MainActor
    func recommendationTailAuthenticationFailureKeepsCardsAndRequestsRevalidation() async {
        let fixture = ContentFixtures(bvid: "BV1AuthRcmd1", title: "认证推荐")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            guard continuation == nil else {
                throw ContentApplicationError.authenticationInvalid
            }
            return fixture.recommendationPage
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMore(.recommendation)
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("认证失效的推荐追加应保留已有卡片")
            return
        }
        #expect(page.videos.count == 1)
        #expect(model.authenticationRevalidationGeneration == 1)
        #expect(
            model.pagination(for: .recommendation(continuation: nil)).loadMoreError
                == .authenticationInvalid
        )
    }

    @Test
    @MainActor
    func popularAndSearchTailAuthenticationFailuresRequestRevalidation() async {
        let fixture = ContentFixtures(bvid: "BV1AuthTail1", title: "认证追加")
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                guard request.page == 1 else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return PopularPage(
                    videos: [fixture.popularVideo],
                    pageNumber: 1,
                    pageSize: request.pageSize,
                    hasMore: true
                )
            },
            search: { request, _ in
                guard request.page == 1 else {
                    throw ContentApplicationError.authenticationInvalid
                }
                return SearchPage(
                    videos: [fixture.searchVideo],
                    pageNumber: 1,
                    pageSize: VideoSearchCriteria.pageSize,
                    totalResults: 40,
                    totalPages: 2
                )
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 1)

        model.activateSearch(VideoSearchCriteria(query: "认证"))
        await model.waitForCurrentTask()
        model.loadMore(.search)
        await model.waitForCurrentTask()
        #expect(model.authenticationRevalidationGeneration == 2)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [BrowseFeed.recommendation, .popular, .search])
    @MainActor
    func authenticationEpochRestartsFeedAndRejectsLateOldResult(_ feed: BrowseFeed) async throws {
        let old = ContentFixtures(bvid: "BV1EpochOld", title: "旧账户结果")
        let fresh = ContentFixtures(bvid: "BV1EpochNew", title: "新账户结果")
        let gates = [TestGate(), TestGate()]
        let repository = FeedRepositoryStub(
            recommendations: { _, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).recommendationPage
            },
            popular: { request, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).popularPage(request)
            },
            search: { request, attempt in
                await gates[attempt - 1].pass()
                return (attempt == 1 ? old : fresh).searchPage(page: request.page)
            }
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        try await gates[0].waitForEntries()

        model.synchronizeAuthenticationSession(generation: 1)
        try await gates[0].waitForCancellations()
        try await gates[1].waitForEntries()
        await gates[1].open()
        await model.waitForCurrentTask()

        model.synchronizeAuthenticationSession(generation: 1)
        await gates[0].open()

        #expect(feed.loadedBVIDs(model) == [fresh.bvid])
        #expect(await repository.requestedPages(feed).count == 2)
    }
}
