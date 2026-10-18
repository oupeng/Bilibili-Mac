import BiliApplication
import BiliBrowseFeature
import Foundation
import SwiftUI

extension SearchFilterSelection {
    /// 工具栏筛选按钮的说明：启用中的筛选按本地化标题列出。
    func summary(locale: Locale) -> String {
        ListFormatter.localizedString(
            byJoining: [
                publication == .all ? nil : publication.localizedTitle(locale: locale),
                duration == .all ? nil : duration.localizedTitle(locale: locale)
            ].compactMap { $0 }
        )
    }
}

/// 搜索页工具栏的排序菜单与筛选按钮（弹窗）：只编辑 `VideoSearchSession` 的筛选选择，并在排序变化或弹窗“应用”时
/// 通知会话；弹窗里的草稿在“应用”前不影响选择。菜单、按钮与弹窗外壳与稍后再看共用（`ToolbarFilterControls`）。
struct SearchToolbarControls: View {
    @Environment(\.locale) private var locale
    @Binding var selection: SearchFilterSelection

    let onSelectOrder: (VideoSearchOrder) -> Void
    let onApplyFilters: (SearchFilterSelection) -> Void

    var body: some View {
        Group {
            ToolbarSortMenu(
                options: VideoSearchOrder.allCases,
                selection: $selection.order,
                title: { $0.localizedTitle(locale: locale) },
                help: AppStrings.localized(
                    "搜索结果排序：\(selection.order.localizedTitle(locale: locale))",
                    locale: locale
                ),
                onSelect: onSelectOrder
            )

            ToolbarFilterButton(
                selection: $selection,
                activeFilterCount: \.activeFilterCount,
                help: filterButtonHelp,
                onApply: onApplyFilters
            ) { draft, cancel, apply in
                SearchFilterPopover(draft: draft, onCancel: cancel, onApply: apply)
            }
        }
    }

    private var filterButtonHelp: String {
        let summary = selection.summary(locale: locale)
        return summary.isEmpty
            ? AppStrings.localized("筛选搜索结果", locale: locale)
            : AppStrings.localized("筛选搜索结果：\(summary)", locale: locale)
    }
}

/// 筛选弹窗：只编辑父视图交来的草稿，“取消”与“应用”交回 `ToolbarFilterButton` 处理。
///
/// 自定义日期范围不合法（`SearchFilterSelection.resolvedFilters()` 抛错）时显示原因并禁用“应用”。
private struct SearchFilterPopover: View {
    @Environment(\.locale) private var locale
    @Binding var draft: SearchFilterSelection
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        FilterPopoverChrome(
            title: AppStrings.localized("筛选搜索结果", locale: locale),
            canReset: draft.activeFilterCount > 0,
            canApply: validationMessage == nil,
            onReset: { draft.resetFilters() },
            onCancel: onCancel,
            onApply: onApply
        ) {
            FilterPickerRow(
                title: AppStrings.localized("发布日期", locale: locale),
                options: VideoPublicationFilter.allCases,
                selection: $draft.publication,
                optionTitle: { $0.localizedTitle(locale: locale) }
            )

            if draft.publication == .custom {
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

    private var validationMessage: String? {
        guard draft.publication == .custom else { return nil }
        do {
            _ = try draft.resolvedFilters()
            return nil
        } catch let error as VideoPublicationRangeError {
            switch error {
            case .startAfterEnd:
                return AppStrings.localized("开始日期不能晚于结束日期", locale: locale)
            case .futureDate:
                return AppStrings.localized("结束日期不能超过今天", locale: locale)
            case .invalidCalendarRange:
                return AppStrings.localized("无法使用这个日期范围", locale: locale)
            }
        } catch {
            return AppStrings.localized("无法使用这个日期范围", locale: locale)
        }
    }
}

extension VideoSearchOrder {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .relevance: AppStrings.localized("综合排序", locale: locale)
        case .mostPlayed: AppStrings.localized("最多播放", locale: locale)
        case .newest: AppStrings.localized("最新发布", locale: locale)
        case .mostDanmaku: AppStrings.localized("最多弹幕", locale: locale)
        case .mostFavorited: AppStrings.localized("最多收藏", locale: locale)
        }
    }
}

extension VideoPublicationFilter {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .all: AppStrings.localized("全部日期", locale: locale)
        case .today: AppStrings.localized("今天", locale: locale)
        case .lastSevenDays: AppStrings.localized("最近一周", locale: locale)
        case .last180Days: AppStrings.localized("最近半年", locale: locale)
        case .custom: AppStrings.localized("自定义日期", locale: locale)
        }
    }
}
