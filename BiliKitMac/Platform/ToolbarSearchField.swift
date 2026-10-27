import AppKit
import SwiftUI

/// 工具栏正中的搜索框宽度：窗口足够宽时取理想宽度，变窄时随工具栏压缩到最小宽度。
enum ToolbarSearchFieldLayout {
    static let minimumWidth: CGFloat = 200
    static let idealWidth: CGFloat = 544
}

/// 工具栏正中的搜索框：AppKit `NSSearchField` 加系统联想菜单（`NSTextSuggestionsDelegate`）。
///
/// SwiftUI `.searchable` 放在工具栏正中时不显示 `.searchSuggestions`，系统联想菜单只能挂在 AppKit
/// 文本框上。回车提交与选中联想都交给调用方的搜索路径；联想只在搜索框编辑时由系统按需索取。
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let history: () -> [String]
    let suggestionSource: SearchSuggestionSource?
    let onSubmit: () -> Void
    let onSelectSuggestion: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.suggestionsDelegate = context.coordinator
        context.coordinator.synchronize(field, with: text)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        context.coordinator.synchronize(field, with: text)
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.cancelSuggestions()
        field.suggestionsDelegate = nil
        field.delegate = nil
        field.target = nil
    }

    /// 搜索框的 delegate、action target 与联想 delegate：在搜索框与 SwiftUI 草稿之间同步文字，
    /// 并提供联想。
    ///
    /// 拥有联想请求 Task：系统重新索取、结束编辑、提交、选中联想与拆除视图时取消，
    /// 旧请求的结果不再交给系统。MainActor 隔离；`parent` 在每次 `updateNSView` 时换成最新的值。
    /// 联想的分区、条数与请求时机见 `SearchSuggestionPolicy`。
    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSTextSuggestionsDelegate {
        typealias SuggestionItemType = String

        var parent: ToolbarSearchField
        private var suggestionTask: Task<Void, Never>?
        /// 搜索框最近一次写进草稿的文字；草稿与它不同，才说明是外部（点选词、关窗清空）改了草稿。
        private var publishedText: String?

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        /// 只把外部改动写回搜索框，且不在输入法组字时写：直接赋值会丢掉未确认的拼音或假名。
        func synchronize(_ field: NSSearchField, with text: String) {
            guard text != publishedText else { return }
            if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() {
                return
            }
            publishedText = text
            if field.stringValue != text {
                field.stringValue = text
            }
        }

        private func publish(_ text: String) {
            publishedText = text
            parent.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            publish(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            cancelSuggestions()
        }

        /// 回车、清除按钮与 Esc 都会发送 action：先同步文字，再交给调用方提交（空白输入由它拒绝）。
        @objc func submit(_ field: NSSearchField) {
            cancelSuggestions()
            publish(field.stringValue)
            parent.onSubmit()
        }

        func cancelSuggestions() {
            suggestionTask?.cancel()
            suggestionTask = nil
        }

        /// 搜索框获得焦点与每次输入变化时系统都会来索取：本机历史立即作为中间结果给出，停顿后再补上
        /// B 站联想。
        func textField(
            _ textField: NSTextField,
            provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void
        ) {
            cancelSuggestions()
            let input = textField.stringValue
            let history = parent.history()
            let local = SearchSuggestionPolicy.sections(
                for: input,
                history: history,
                suggestions: []
            )
            guard let source = parent.suggestionSource,
                SearchSuggestionPolicy.requestsSuggestions(for: input)
            else {
                responseHandler(Self.response(for: local, phase: .final))
                return
            }
            responseHandler(Self.response(for: local, phase: .intermediate))
            suggestionTask = Task { @MainActor in
                try? await Task.sleep(for: SearchSuggestionPolicy.requestDelay)
                guard !Task.isCancelled else { return }
                let suggestions = await source.suggestions(for: input)
                guard !Task.isCancelled else { return }
                responseHandler(
                    Self.response(
                        for: SearchSuggestionPolicy.sections(
                            for: input,
                            history: history,
                            suggestions: suggestions
                        ),
                        phase: .final
                    )
                )
            }
        }

        func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
            item.representedValue
        }

        /// 选中联想（回车或点击）只回调一次，且不会触发搜索框 action；在这里发起搜索。
        func textField(_ textField: NSTextField, didSelect item: Item) {
            cancelSuggestions()
            textField.stringValue = item.representedValue
            publishedText = item.representedValue
            parent.onSelectSuggestion(item.representedValue)
        }

        private static func response(
            for sections: SearchSuggestionPolicy.Sections,
            phase: ItemResponse.Phase
        ) -> ItemResponse {
            var itemSections: [ItemSection] = []
            if !sections.history.isEmpty {
                itemSections.append(
                    ItemSection(
                        title: AppStrings.localized("搜索历史"),
                        items: sections.history.map(historyItem)
                    )
                )
            }
            if !sections.suggestions.isEmpty {
                itemSections.append(
                    ItemSection(
                        title: AppStrings.localized("搜索联想"),
                        items: sections.suggestions.map { Item(representedValue: $0, title: $0) }
                    )
                )
            }
            var response = ItemResponse(itemSections: itemSections)
            response.phase = phase
            return response
        }

        private static func historyItem(_ query: String) -> Item {
            var item = Item(representedValue: query, title: query)
            item.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            return item
        }
    }
}
