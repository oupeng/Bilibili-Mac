import BiliApplication
import BiliModels
import Foundation
import Testing

/// 稍后再看用例不为非正页码发请求，并拒收页码与请求不符或下一页不紧接着的响应。
@Suite(.timeLimit(.minutes(1)))
struct WatchLaterUseCaseTests {
    @Test
    func returnsTheRequestedPage() async throws {
        let repository = WatchLaterRepositoryStub(
            page: WatchLaterPage(items: [], pageNumber: 2, nextPageNumber: 3)
        )

        let page = try await WatchLaterUseCase(repository: repository).load(page: 2)

        #expect(page.nextPageNumber == 3)
        #expect(await repository.requestedPages == [2])
    }

    @Test(arguments: [0, -1])
    func nonPositivePageSendsNothing(page: Int) async {
        let repository = WatchLaterRepositoryStub(
            page: WatchLaterPage(items: [], pageNumber: 1, nextPageNumber: nil)
        )

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await WatchLaterUseCase(repository: repository).load(page: page)
        }
        #expect(await repository.requestedPages.isEmpty)
    }

    @Test(arguments: [
        WatchLaterPage(items: [], pageNumber: 3, nextPageNumber: nil),
        WatchLaterPage(items: [], pageNumber: 2, nextPageNumber: 2),
        WatchLaterPage(items: [], pageNumber: 2, nextPageNumber: 5)
    ])
    func misplacedPageIsAnInvalidResponse(response: WatchLaterPage) async {
        let repository = WatchLaterRepositoryStub(page: response)

        await #expect(throws: ContentApplicationError.invalidResponse) {
            try await WatchLaterUseCase(repository: repository).load(page: 2)
        }
    }
}

/// 本 target 唯一的稍后再看仓库替身：总是返回同一页并记录请求的页码。
private actor WatchLaterRepositoryStub: WatchLaterRepository {
    private let page: WatchLaterPage
    private(set) var requestedPages: [Int] = []

    init(page: WatchLaterPage) {
        self.page = page
    }

    func watchLater(page: Int) async throws -> WatchLaterPage {
        requestedPages.append(page)
        return self.page
    }
}
