import BiliApplication
import BiliLibraryFeature
import Foundation
import SwiftUI

/// 稍后再看工具栏的排序菜单与筛选按钮（弹窗）：只编辑 `WatchLaterSession` 的筛选选择，并在排序变化或弹窗“应用”时
/// 通知会话；弹窗里的草稿在“应用”前不影响选择。
///
/// 菜单、按钮与弹窗外壳与搜索共用（`ToolbarFilterControls`）。
struct WatchLaterToolbarControls: View {
    @Environment(\.locale) private var locale
    @Bindable var session: WatchLaterSession

    var body: some View {
        Group {
            ToolbarSortMenu(
                options: WatchLaterOrder.allCases,
                selection: $session.filterSelection.order,
                title: { $0.localizedTitle(locale: locale) },
                help: AppStrings.localized(
                    "稍后再看排序：\(session.filterSelection.order.localizedTitle(locale: locale))",
                    locale: locale
                ),
                onSelect: session.selectOrder
            )

            ToolbarFilterButton(
                selection: $session.filterSelection,
                activeFilterCount: \.activeFilterCount,
                help: filterButtonHelp,
                onApply: session.applyFilters,
                popover: { draft, cancel, apply in
                    WatchLaterFilterPopover(draft: draft, onCancel: cancel, onApply: apply)
                }
            )
        }
    }

    private var filterButtonHelp: String {
        let selection = session.filterSelection
        let summary = ListFormatter.localizedString(
            byJoining: [
                selection.progress == .all
                    ? nil : selection.progress.localizedTitle(locale: locale),
                selection.addedTime == .all
                    ? nil : selection.addedTime.localizedTitle(locale: locale),
                selection.duration == .all ? nil : selection.duration.localizedTitle(locale: locale)
            ].compactMap { $0 }
        )
        return summary.isEmpty
            ? AppStrings.localized("筛选稍后再看", locale: locale)
            : AppStrings.localized("筛选稍后再看：\(summary)", locale: locale)
    }
}

/// 稍后再看的筛选弹窗：观看进度、加入时间（自定义时两个仅日期的选择器）与时长三组，只编辑父视图交来的草稿。
///
/// 自定义的开始日晚于结束日（`WatchLaterFilterSelection.resolvedAddedTime()` 抛错）时显示原因并禁用“应用”。
private struct WatchLaterFilterPopover: View {
    @Environment(\.locale) private var locale
    @Binding var draft: WatchLaterFilterSelection
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        FilterPopoverChrome(
            title: AppStrings.localized("筛选稍后再看", locale: locale),
            canReset: draft.activeFilterCount > 0,
            canApply: validationMessage == nil,
            onReset: resetDraft,
            onCancel: onCancel,
            onApply: onApply
        ) {
            FilterPickerRow(
                title: AppStrings.localized("观看进度", locale: locale),
                options: WatchLaterProgressFilter.allCases,
                selection: $draft.progress,
                optionTitle: { $0.localizedTitle(locale: locale) }
            )

            FilterPickerRow(
                title: AppStrings.localized("添加时间", locale: locale),
                options: WatchLaterAddedTimeFilter.allCases,
                selection: $draft.addedTime,
                optionTitle: { $0.localizedTitle(locale: locale) }
            )

            if draft.addedTime == .custom {
                CustomDateRangeFields(
                    start: $draft.customStart,
                    end: $draft.customEnd,
                    validationMessage: validationMessage
                )
            }

            FilterPickerRow(
                title: AppStrings.localized("视频时长", locale: locale),
                options: VideoDurationFilter.allCases,
                selection: $draft.duration,
                optionTitle: { $0.localizedTitle(locale: locale) }
            )
        }
    }

    private func resetDraft() {
        draft.resetFilters()
    }

    private var validationMessage: String? {
        guard draft.addedTime == .custom else { return nil }
        do {
            _ = try draft.resolvedAddedTime()
            return nil
        } catch WatchLaterAddedTimeRangeError.startAfterEnd {
            return AppStrings.localized("开始日期不能晚于结束日期", locale: locale)
        } catch {
            return AppStrings.localized("无法使用这个日期范围", locale: locale)
        }
    }
}

extension WatchLaterOrder {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .newestAdded: AppStrings.localized("最近添加", locale: locale)
        case .oldestAdded: AppStrings.localized("最早添加", locale: locale)
        }
    }
}

extension WatchLaterProgressFilter {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部进度", locale: locale)
        case .unfinished: AppStrings.localized("未看完", locale: locale)
        }
    }
}

extension WatchLaterAddedTimeFilter {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部时间", locale: locale)
        case .today: AppStrings.localized("今天", locale: locale)
        case .yesterday: AppStrings.localized("昨天", locale: locale)
        case .lastSevenDays: AppStrings.localized("近一周", locale: locale)
        case .custom: AppStrings.localized("自定义日期", locale: locale)
        }
    }
}
