import BiliApplication
import Foundation

/// 搜索框联想菜单的内容规则：本机历史在前、B 站联想在后，两区不重复。
enum SearchSuggestionPolicy {
    /// 历史区最多列出的条数；历史只在本机匹配，不联网。
    ///
    /// 调大会把 B 站联想挤到菜单更下方。
    static let historyLimit = 3
    /// 停止输入这么久之后才请求 B 站联想；期间的新输入取消旧请求。
    ///
    /// 调短请求更频繁，调长联想出现得更慢。
    static let requestDelay: Duration = .milliseconds(250)

    /// 联想菜单的两区内容：匹配当前输入的本机历史，以及去掉历史中已有词的 B 站联想。
    struct Sections: Equatable {
        let history: [String]
        let suggestions: [String]
    }

    /// 输入能作为搜索词时才向 B 站请求联想。
    static func requestsSuggestions(for input: String) -> Bool {
        VideoSearchCriteria(query: input).isValid
    }

    /// 历史区取包含当前输入的词（不区分大小写，最近的在前）；联想区去掉已在历史区出现的词（同样不区分
    /// 大小写，B 站搜索本身不区分）。
    static func sections(
        for input: String,
        history: [String],
        suggestions: [String]
    ) -> Sections {
        let query = VideoSearchCriteria(query: input).query
        guard !query.isEmpty else { return Sections(history: [], suggestions: []) }
        let matchingHistory = Array(
            history.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(historyLimit)
        )
        return Sections(
            history: matchingHistory,
            suggestions: suggestions.filter { suggestion in
                !matchingHistory.contains {
                    $0.compare(suggestion, options: .caseInsensitive) == .orderedSame
                }
            }
        )
    }
}

/// 窗口工具栏搜索框取 B 站联想的入口；失败与取消都视为没有联想，不打断输入。
struct SearchSuggestionSource: Sendable {
    private let useCase: SearchSuggestionUseCase

    init(useCase: SearchSuggestionUseCase) {
        self.useCase = useCase
    }

    func suggestions(for input: String) async -> [String] {
        (try? await useCase.suggestions(for: input)) ?? []
    }
}
