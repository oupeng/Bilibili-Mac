import BiliApplication
import Foundation
import SwiftUI

/// 工具栏的排序菜单：每个选项一个勾选项，选中即生效。
///
/// 搜索与稍后再看共用，选项与文案由调用方给出。
struct ToolbarSortMenu<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let help: String
    let onSelect: (Option) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Toggle(
                    isOn: Binding(
                        get: { selection == option },
                        set: { isSelected in
                            guard isSelected else { return }
                            selection = option
                            onSelect(option)
                        }
                    )
                ) {
                    Text(title(option))
                }
            }
        } label: {
            Label {
                Text(title(selection))
            } icon: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .labelStyle(.titleAndIcon)
        }
        .help(help)
    }
}

/// 工具栏的筛选按钮与弹窗：按钮标题与图标体现启用中的筛选数，弹窗编辑一份草稿，“应用”前不影响选择。
///
/// 搜索与稍后再看共用。拥有草稿与弹窗是否显示（`@State`）；选择本身归调用方的会话，应用时写回并回调。弹窗关闭
/// （含点外面取消）时草稿丢弃，下次打开从当前选择重新开始。
struct ToolbarFilterButton<Selection: Equatable, Popover: View>: View {
    @Environment(\.locale) private var locale
    @Binding var selection: Selection
    @State private var draft: Selection
    @State private var isPopoverPresented = false
    let activeFilterCount: (Selection) -> Int
    let help: String
    let onApply: (Selection) -> Void
    let popover:
        (_ draft: Binding<Selection>, _ cancel: @escaping () -> Void, _ apply: @escaping () -> Void)
            -> Popover

    init(
        selection: Binding<Selection>,
        activeFilterCount: @escaping (Selection) -> Int,
        help: String,
        onApply: @escaping (Selection) -> Void,
        @ViewBuilder popover:
            @escaping (
                _ draft: Binding<Selection>,
                _ cancel: @escaping () -> Void,
                _ apply: @escaping () -> Void
            ) -> Popover
    ) {
        _selection = selection
        _draft = State(initialValue: selection.wrappedValue)
        self.activeFilterCount = activeFilterCount
        self.help = help
        self.onApply = onApply
        self.popover = popover
    }

    var body: some View {
        let count = activeFilterCount(selection)
        Button {
            draft = selection
            isPopoverPresented = true
        } label: {
            Label {
                Text(
                    count == 0
                        ? AppStrings.localized("筛选", locale: locale)
                        : AppStrings.localized("筛选 \(count)", locale: locale)
                )
            } icon: {
                Image(
                    systemName: count == 0
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityValue(Text(AppStrings.localized("已启用 \(count) 项", locale: locale)))
        .help(help)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            popover($draft, cancelDraft, applyDraft)
        }
        .onChange(of: isPopoverPresented) { _, isPresented in
            if !isPresented {
                draft = selection
            }
        }
    }

    private func cancelDraft() {
        draft = selection
        isPopoverPresented = false
    }

    private func applyDraft() {
        selection = draft
        isPopoverPresented = false
        onApply(draft)
    }
}

/// 筛选弹窗的外壳：标题、调用方的筛选行，以及“恢复默认／取消／应用”。
///
/// 搜索与稍后再看共用。
struct FilterPopoverChrome<Content: View>: View {
    @Environment(\.locale) private var locale
    let title: String
    let canReset: Bool
    let canApply: Bool
    let onReset: () -> Void
    let onCancel: () -> Void
    let onApply: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)

            content

            Divider()

            HStack {
                Button(AppStrings.localized("恢复默认", locale: locale), action: onReset)
                    .disabled(!canReset)
                Spacer()
                Button(AppStrings.localized("取消", locale: locale), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(AppStrings.localized("应用", locale: locale), action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding(16)
        .frame(width: 350)
    }
}

/// 筛选弹窗里的一行选项：左侧标题，右侧固定宽度的弹出菜单。
struct FilterPickerRow<Option: Hashable & Identifiable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let optionTitle: (Option) -> String

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(optionTitle(option)).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 176)
        }
    }
}

/// 自定义日期范围的两个仅日期选择器；不合法时在下方显示原因（由调用方按自己的规则给出）。
struct CustomDateRangeFields: View {
    @Environment(\.locale) private var locale
    @Binding var start: Date
    @Binding var end: Date
    let validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker(
                AppStrings.localized("开始日期", locale: locale),
                selection: $start,
                in: ...Date(),
                displayedComponents: .date
            )
            DatePicker(
                AppStrings.localized("结束日期", locale: locale),
                selection: $end,
                in: ...Date(),
                displayedComponents: .date
            )
            if let validationMessage {
                Label {
                    Text(validationMessage)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.red)
            }
        }
        .padding(.leading, 12)
    }
}

extension VideoDurationFilter {
    /// 时长四档的标题；搜索与稍后再看的筛选弹窗都在 App，这里是这组文案的唯一位置。
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部时长", locale: locale)
        case .underTenMinutes: AppStrings.localized("10 分钟以下", locale: locale)
        case .tenToThirtyMinutes: AppStrings.localized("10–30 分钟", locale: locale)
        case .thirtyToSixtyMinutes: AppStrings.localized("30–60 分钟", locale: locale)
        case .overSixtyMinutes: AppStrings.localized("60 分钟以上", locale: locale)
        }
    }
}
