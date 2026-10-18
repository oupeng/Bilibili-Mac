/// `/x/web-interface/suggest` 的 `data`；只读取 `result.tag[].value`，高亮 HTML（`name`）不解析。
///
/// 这里只做 DTO 到模型的映射；规范化、去重与条数上限由 `SearchSuggestionUseCase` 决定。
struct SearchSuggestionPayload: Decodable, Sendable {
    let result: SearchSuggestionResultPayload?

    func model() -> [String] {
        result?.tag.compactMap(\.value?.value) ?? []
    }
}

/// 联想的 `result`：单项解码失败只丢该项。
struct SearchSuggestionResultPayload: Decodable, Sendable {
    let tag: [LossyDecodable<SearchSuggestionTagPayload>]
}

/// 联想的一项，只取纯文本 `value`。
struct SearchSuggestionTagPayload: Decodable, Sendable {
    let value: String
}
