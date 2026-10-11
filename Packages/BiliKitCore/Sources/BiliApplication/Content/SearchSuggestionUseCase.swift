/// 搜索框联想：输入按搜索规则规范化后才请求，结果只保留能作为合法搜索词的条目，去重并限制条数。
public struct SearchSuggestionUseCase: Sendable {
    public static let suggestionLimit = 10

    private let repository: any SearchSuggestionRepository

    public init(repository: any SearchSuggestionRepository) {
        self.repository = repository
    }

    /// 空白或超过搜索长度上限的输入不发请求，直接返回空。
    public func suggestions(for term: String) async throws -> [String] {
        let input = VideoSearchCriteria(query: term)
        guard input.isValid else { return [] }
        let suggestions = try await repository.searchSuggestions(for: input.query)
        try Task.checkCancellation()
        return VideoSearchCriteria.uniqueQueries(from: suggestions, limit: Self.suggestionLimit)
    }
}
