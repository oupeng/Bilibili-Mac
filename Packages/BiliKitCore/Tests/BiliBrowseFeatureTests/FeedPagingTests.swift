import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliBrowseFeature

/// 推荐、热门与搜索的分页：按 BVID 去重追加，无进展或达到保留上限即停止，追加失败保留卡片、只重试下一页。
@Suite(.timeLimit(.minutes(1)))
struct FeedPagingTests {
    @Test
    @MainActor
    func recommendationBatchesAppendDeduplicateAndStopWithoutProgress() async {
        let first = ContentFixtures(bvid: "BV1RcmdOneA", title: "推荐一")
        let second = ContentFixtures(bvid: "BV1RcmdTwoB", title: "推荐二")
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let freshIndex = continuation?.freshIndex ?? 1
            let videos: [RecommendedVideo]
            switch freshIndex {
            case 1: videos = [first.recommendedVideo, first.recommendedVideo]
            case 2: videos = [first.recommendedVideo, second.recommendedVideo]
            case 3: videos = [second.recommendedVideo]
            default: throw ContentApplicationError.invalidRequest
            }
            return RecommendationPage(
                videos: videos,
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        #expect(model.pagination(for: .recommendation(continuation: nil)).canLoadMore)

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let secondBatch)) = model.state else {
            Issue.record("推荐追加后应保持 loaded")
            return
        }
        #expect(secondBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(secondBatch.nextContinuation == RecommendationContinuation(freshIndex: 3))

        model.loadMore(.recommendation)
        await model.waitForCurrentTask()
        guard case .loaded(.recommendation(let finalBatch)) = model.state else {
            Issue.record("全重复推荐批次后应保持 loaded")
            return
        }
        #expect(finalBatch.videos.map(\.bvid) == [first.bvid, second.bvid])
        #expect(finalBatch.nextContinuation == nil)
        #expect(!model.pagination(for: .recommendation(continuation: nil)).canLoadMore)
        #expect(await repository.recommendationRequests.count == 3)
    }

    @Test
    @MainActor
    func recommendationWorksetStopsAtItsRetainedCapacity() async {
        let repository = FeedRepositoryStub(recommendations: { continuation, _ in
            let freshIndex = continuation?.freshIndex ?? 1
            let range = freshIndex == 1 ? 0..<999 : 999..<1_004
            return RecommendationPage(
                videos: range.map { index in
                    ContentFixtures(
                        bvid: "BV-capacity-\(index)",
                        title: "推荐 \(index)"
                    ).recommendedVideo
                },
                continuation: RecommendationContinuation(freshIndex: freshIndex),
                nextContinuation: RecommendationContinuation(freshIndex: freshIndex + 1)
            )
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        model.activateRecommendation()
        await model.waitForCurrentTask()
        model.loadMore(.recommendation)
        await model.waitForCurrentTask()

        guard case .loaded(.recommendation(let page)) = model.state else {
            Issue.record("推荐达到容量后应保持 loaded")
            return
        }
        #expect(
            page.videos.count
                == VideoListRetention.maximumItemCount
        )
        #expect(page.nextContinuation == nil)
        #expect(!model.pagination(for: .recommendation(continuation: nil)).canLoadMore)
    }

    /// 热门与搜索与推荐共用上限：达到后不再给出分页尾标，也不再请求下一页。
    @Test
    @MainActor
    func popularAndSearchStopPaginatingAtTheSharedCapacity() async {
        let videosPerPage = 300
        let pageVideos: @Sendable (String, Int) -> [ContentFixtures] = { prefix, page in
            ((page - 1) * videosPerPage..<page * videosPerPage).map { index in
                ContentFixtures(bvid: "BV-\(prefix)-\(index)", title: "\(prefix) \(index)")
            }
        }
        let repository = FeedRepositoryStub(
            popular: { request, _ in
                PopularPage(
                    videos: pageVideos("popular", request.page).map(\.popularVideo),
                    pageNumber: request.page,
                    pageSize: request.pageSize,
                    hasMore: true
                )
            },
            search: { request, _ in
                SearchPage(
                    videos: pageVideos("search", request.page).map(\.searchVideo),
                    pageNumber: request.page,
                    pageSize: request.criteria.pageSize,
                    totalResults: 100 * videosPerPage,
                    totalPages: 100
                )
            }
        )
        let model = BrowseViewModel(useCase: FeedUseCase(repository: repository))
        let popularRequest = FeedRequest.popular(page: 1, pageSize: 50)
        let searchCriteria = VideoSearchCriteria(query: "上限")
        let searchRequest = FeedRequest.search(
            VideoSearchRequest(criteria: searchCriteria, page: 1)
        )

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        for _ in 0..<5 {
            model.loadMore(.popular)
            await model.waitForCurrentTask()
        }
        guard case .loaded(.popular(let popularPage)) = model.state else {
            Issue.record("热门达到上限后应保持 loaded")
            return
        }
        #expect(popularPage.videos.count == VideoListRetention.maximumItemCount)
        #expect(model.pagination(for: popularRequest).tailIdentity == nil)
        #expect(!model.pagination(for: popularRequest).canLoadMore)
        #expect(await repository.popularPages == [1, 2, 3, 4])

        model.activateSearch(searchCriteria)
        await model.waitForCurrentTask()
        for _ in 0..<5 {
            model.loadMore(.search)
            await model.waitForCurrentTask()
        }
        guard case .loaded(.search(_, let searchPage)) = model.state else {
            Issue.record("搜索达到上限后应保持 loaded")
            return
        }
        #expect(searchPage.videos.count == VideoListRetention.maximumItemCount)
        #expect(model.pagination(for: searchRequest).tailIdentity == nil)
        #expect(!model.pagination(for: searchRequest).canLoadMore)
        #expect(await repository.searchRequests.map(\.page) == [1, 2, 3, 4])
    }

    @Test
    @MainActor
    func duplicateOnlyPopularPageStopsNonProgressingPagination() async {
        let fixture = ContentFixtures(bvid: "BV1PopularE5", title: "重复热门卡片")
        let repository = FeedRepositoryStub(popular: { request, _ in
            fixture.popularPage(request, hasMore: true)
        })
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )
        let request = FeedRequest.popular(page: 1, pageSize: 50)

        model.activatePopular(pageSize: 50)
        await model.waitForCurrentTask()
        model.loadMore(.popular)
        await model.waitForCurrentTask()

        guard case .loaded(.popular(let page)) = model.state else {
            Issue.record("全重复分页后应保持 loaded")
            return
        }
        #expect(page.videos.map(\.bvid) == [fixture.bvid])
        #expect(page.pageNumber == 2)
        #expect(!page.hasMore)
        #expect(!model.pagination(for: request).canLoadMore)
        #expect(await repository.popularPages.count == 2)
    }

    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func nearEndAppendsDeduplicatesAndBackpressuresSameTail(_ feed: BrowseFeed) async {
        let first = ContentFixtures(bvid: "BV1PagedA1", title: "第一页")
        let second = ContentFixtures(bvid: "BV1PagedB2", title: "第二页")
        let repository = FeedRepositoryStub.pagination(feed, first: first, second: second)
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        let firstTail = feed.pagination(model)
        #expect(firstTail.canLoadMore)
        #expect(firstTail.tailIdentity?.contains("|1|") == true)

        feed.loadMore(model)
        feed.loadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2])
        #expect(!feed.pagination(model).canLoadMore)
    }

    @Test(arguments: [BrowseFeed.popular, .search])
    @MainActor
    func failedAppendKeepsCardsAndRetriesOnlyNextPage(_ feed: BrowseFeed) async {
        let first = ContentFixtures(bvid: "BV1PagedC3", title: "保留卡片")
        let second = ContentFixtures(bvid: "BV1PagedD4", title: "重试追加")
        let repository = FeedRepositoryStub.pagination(
            feed,
            first: first,
            second: second,
            failsFirstSecondPage: true
        )
        let model = BrowseViewModel(
            useCase: FeedUseCase(repository: repository)
        )

        feed.activate(model)
        await model.waitForCurrentTask()
        let loadedState = model.state

        feed.loadMore(model)
        await model.waitForCurrentTask()
        let failed = feed.pagination(model)
        #expect(model.state == loadedState)
        #expect(failed.loadMoreError == .transportFailure)
        #expect(!failed.canLoadMore)
        #expect(failed.tailIdentity == nil)

        feed.retryLoadMore(model)
        await model.waitForCurrentTask()

        #expect(feed.loadedBVIDs(model) == [first.bvid, second.bvid])
        #expect(await repository.requestedPages(feed) == [1, 2, 2])
        #expect(
            await repository.searchRequests.allSatisfy { $0.criteria == BrowseFeed.searchCriteria }
        )
    }
}
