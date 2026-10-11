import BiliApplication
import BiliModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TrendingSearchUseCaseTests {
    @Test
    func keepsOnlySearchableUniqueKeywordsUpToTheLimit() async throws {
        let overlong = String(repeating: "长", count: VideoSearchCriteria.maximumQueryLength + 1)
        let repository = TrendingSearchRepositoryStub(
            keywords: [
                .fixture(" 词一 ", displayName: " "),
                .fixture("词一", displayName: "重复"),
                .fixture(overlong),
                .fixture("词二", displayName: "词二 · 展示")
            ]
                + (3...20).map { .fixture("词\($0)") }
        )
        let useCase = TrendingSearchUseCase(repository: repository)

        let keywords = try await useCase.trendingKeywords()

        #expect(await repository.requestedLimits == [TrendingSearchUseCase.keywordLimit])
        #expect(keywords.count == TrendingSearchUseCase.keywordLimit)
        // 关键词按搜索规则规范化；空白展示名退回关键词。
        #expect(keywords[0] == .fixture("词一", displayName: "词一"))
        #expect(keywords[1] == .fixture("词二", displayName: "词二 · 展示"))
        #expect(keywords.map(\.keyword).dropFirst(2).first == "词3")
    }
}

private actor TrendingSearchRepositoryStub: TrendingSearchRepository {
    let keywords: [TrendingSearchKeyword]
    private(set) var requestedLimits: [Int] = []

    init(keywords: [TrendingSearchKeyword]) {
        self.keywords = keywords
    }

    func trendingSearchKeywords(limit: Int) async throws -> [TrendingSearchKeyword] {
        requestedLimits.append(limit)
        return keywords
    }
}

extension TrendingSearchKeyword {
    fileprivate static func fixture(
        _ keyword: String,
        displayName: String? = nil
    ) -> TrendingSearchKeyword {
        TrendingSearchKeyword(
            keyword: keyword,
            displayName: displayName ?? keyword,
            iconURL: nil
        )
    }
}
