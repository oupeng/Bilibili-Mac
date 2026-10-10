import SwiftUI

/// 空间列表底部悬浮的玻璃页码条。
///
/// 收起时只显示“第 n / 总 页”；指针移上去展开为 `‹ 1 … 5 6 [7] 8 9 … N ›`，点数字翻页，
/// 点当前页原地输入页码跳转。指针移开、Esc 或失焦时取消输入并收起。VoiceOver 用户无法悬停，
/// 收起状态提供上下调整翻页与“输入页码跳转”操作。
struct UploaderSpacePager: View {
    let currentPage: Int
    let pageCount: Int
    let onShowPage: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isFieldFocused: Bool

    private var isExpanded: Bool {
        isHovered || isEditing
    }

    var body: some View {
        // 同一行里逐个插入／移除元素，宽度变化由玻璃条本身做过渡，而不是整块内容替换。
        HStack(spacing: UploaderSpaceGeometry.pagerItemSpacing) {
            if isExpanded {
                arrow("chevron.left", label: AppStrings.localized("上一页"), target: currentPage - 1)
                    .transition(expansionTransition)
                ForEach(
                    UploaderSpacePageSlots.slots(currentPage: currentPage, pageCount: pageCount),
                    id: \.self
                ) { slot in
                    switch slot {
                    case .page(let page) where page == currentPage:
                        currentPageControl
                    case .page(let page):
                        pageButton(page)
                    case .gap:
                        Text(verbatim: "…")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: UploaderSpaceGeometry.pagerGapWidth)
                            .accessibilityHidden(true)
                    }
                }
                .transition(expansionTransition)
                arrow("chevron.right", label: AppStrings.localized("下一页"), target: currentPage + 1)
                    .transition(expansionTransition)
            } else {
                collapsedLabel
                    .transition(.opacity)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, UploaderSpaceGeometry.pagerHorizontalPadding)
        .padding(.vertical, UploaderSpaceGeometry.pagerVerticalPadding)
        .modifier(UploaderSpacePagerBackground())
        .contentShape(Capsule())
        .animation(
            reduceMotion ? nil : .snappy(duration: UploaderSpaceGeometry.pagerExpansionDuration),
            value: isExpanded
        )
        .onHover { hovering in
            isHovered = hovering
            // 移开即恢复原样：取消输入、收起。
            if !hovering { endEditing() }
        }
        .padding(.bottom, UploaderSpaceGeometry.pagerBottomInset)
        .frame(maxWidth: .infinity)
    }

    private var expansionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: UploaderSpaceGeometry.pagerExpansionScale))
    }

    private var collapsedLabel: some View {
        Text(AppStrings.localized("第 \(currentPage) / \(pageCount) 页"))
            .monospacedDigit()
            .padding(.horizontal, UploaderSpaceGeometry.pagerCollapsedLabelPadding)
            .accessibilityElement()
            .accessibilityLabel(AppStrings.localized("页码"))
            .accessibilityValue(AppStrings.localized("第 \(currentPage) 页，共 \(pageCount) 页"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: commit(currentPage + 1)
                case .decrement: commit(currentPage - 1)
                @unknown default: break
                }
            }
            .accessibilityAction(named: AppStrings.localized("输入页码跳转")) {
                beginEditing()
            }
    }

    private func arrow(_ symbol: String, label: String, target: Int) -> some View {
        Button {
            commit(target)
        } label: {
            Image(systemName: symbol)
                .frame(
                    width: UploaderSpaceGeometry.pagerItemSize,
                    height: UploaderSpaceGeometry.pagerItemSize
                )
                .contentShape(Rectangle())
        }
        .disabled(target < 1 || target > pageCount)
        .help(label)
        .accessibilityLabel(label)
    }

    private func pageButton(_ page: Int) -> some View {
        Button {
            commit(page)
        } label: {
            pageNumber(page, isCurrent: false)
        }
        .accessibilityLabel(AppStrings.localized("第 \(page) 页，共 \(pageCount) 页"))
    }

    @ViewBuilder
    private var currentPageControl: some View {
        if isEditing {
            TextField(AppStrings.localized("页码"), text: $editText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .frame(
                    width: UploaderSpaceGeometry.pagerFieldWidth,
                    height: UploaderSpaceGeometry.pagerItemSize
                )
                .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                .focused($isFieldFocused)
                .onSubmit(submitEdit)
                .onExitCommand(perform: endEditing)
                .onChange(of: isFieldFocused) { _, focused in
                    if !focused { endEditing() }
                }
        } else {
            Button(action: beginEditing) {
                pageNumber(currentPage, isCurrent: true)
            }
            .help(AppStrings.localized("输入页码跳转"))
            .accessibilityLabel(AppStrings.localized("第 \(currentPage) 页，共 \(pageCount) 页"))
            .accessibilityHint(AppStrings.localized("输入页码跳转"))
            .accessibilityAddTraits(.isSelected)
        }
    }

    private func pageNumber(_ page: Int, isCurrent: Bool) -> some View {
        Text(verbatim: "\(page)")
            .monospacedDigit()
            .frame(
                minWidth: UploaderSpaceGeometry.pagerItemSize,
                minHeight: UploaderSpaceGeometry.pagerItemSize
            )
            .padding(.horizontal, UploaderSpaceGeometry.pagerNumberPadding)
            .background {
                if isCurrent {
                    Capsule().fill(Color.accentColor.opacity(0.25))
                }
            }
            .contentShape(Capsule())
    }

    private func beginEditing() {
        editText = ""
        isEditing = true
        isFieldFocused = true
    }

    private func submitEdit() {
        if let page = Int(editText.trimmingCharacters(in: .whitespaces)) {
            commit(page)
        }
        endEditing()
    }

    private func endEditing() {
        isEditing = false
        isFieldFocused = false
        editText = ""
    }

    /// 超出范围的页码修正到首页或末页；当前页不重复请求。
    private func commit(_ page: Int) {
        let clamped = min(max(1, page), pageCount)
        guard clamped != currentPage else { return }
        onShowPage(clamped)
    }
}

/// 页码条的浮动背景；macOS 26 起用玻璃。
private struct UploaderSpacePagerBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
