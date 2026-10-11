import BiliApplication
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SearchSuggestionUseCaseTests {
    @Test(arguments: [
        "", "   ", String(repeating: "长", count: VideoSearchCriteria.maximumQueryLength + 1)
    ])
    func inputThatCannotBeSearchedSendsNoRequest(input: String) async throws {
        let repository = SearchSuggestionRepositoryStub(suggestions: ["词一"])
        let useCase = SearchSuggestionUseCase(repository: repository)

        #expect(try await useCase.suggestions(for: input).isEmpty)
        #expect(await repository.requestedTerms.isEmpty)
    }

    @Test
    func keepsSearchableUniqueSuggestionsUpToTheLimit() async throws {
        let overlong = String(repeating: "长", count: VideoSearchCriteria.maximumQueryLength + 1)
        let repository = SearchSuggestionRepositoryStub(
            suggestions: [" 词一 ", "词一", "  ", overlong, "词二"] + (3...20).map { "词\($0)" }
        )
        let useCase = SearchSuggestionUseCase(repository: repository)

        let suggestions = try await useCase.suggestions(for: "  词 ")

        // 请求前按搜索规则规范化输入。
        #expect(await repository.requestedTerms == ["词"])
        #expect(suggestions.count == SearchSuggestionUseCase.suggestionLimit)
        #expect(Array(suggestions.prefix(3)) == ["词一", "词二", "词3"])
    }
}

private actor SearchSuggestionRepositoryStub: SearchSuggestionRepository {
    let suggestions: [String]
    private(set) var requestedTerms: [String] = []

    init(suggestions: [String]) {
        self.suggestions = suggestions
    }

    func searchSuggestions(for term: String) async throws -> [String] {
        requestedTerms.append(term)
        return suggestions
    }
}
