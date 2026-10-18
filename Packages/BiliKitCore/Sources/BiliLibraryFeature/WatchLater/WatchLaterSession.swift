import BiliApplication
import Foundation
import Observation

/// 稍后再看筛选弹窗与排序菜单编辑的选择：排序、观看进度、加入时间（含自定义日期）与时长。
///
/// 值类型，App 的弹窗持有它的草稿副本，“应用”前不影响会话；排序在菜单里选中即生效。
public struct WatchLaterFilterSelection: Hashable, Sendable {
    public var order = WatchLaterOrder.newestAdded
    public var progress = WatchLaterProgressFilter.all
    public var addedTime = WatchLaterAddedTimeFilter.all
    public var customStart =
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    public var customEnd = Date()
    public var duration = VideoDurationFilter.all

    public init() {}

    /// 启用中的筛选数（排序不算）。
    public var activeFilterCount: Int {
        (progress == .all ? 0 : 1) + (addedTime == .all ? 0 : 1) + (duration == .all ? 0 : 1)
    }

    /// 清除进度、加入时间与时长筛选，保留排序。
    public mutating func resetFilters() {
        progress = .all
        addedTime = .all
        duration = .all
    }

    /// 按 `now` 与 `calendar` 把加入时间解析为冻结的区间；自定义的开始日晚于结束日时抛出
    /// `WatchLaterAddedTimeRangeError`。
    public func resolvedAddedTime(
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> WatchLaterAddedTimeRange? {
        try WatchLaterAddedTimeRangeResolver.resolve(
            filter: addedTime,
            customStart: customStart,
            customEnd: customEnd,
            now: now,
            calendar: calendar
        )
    }
}

/// 稍后再看来源的会话：工具栏的搜索草稿、排序与筛选选择、已应用的条件，以及条件变化到列表重新加载的映射。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有草稿、选择与已应用的条件（只在窗口内存里，不持久化，见
/// SECURITY-MODEL §6）；不拥有请求、分页、generation 与复核（`WatchLaterViewModel`）。条件变化（排序、应用筛选、
/// 提交或清空关键词）都以新条件的第一页从空列表重新加载（`LibraryVideoListModel.reloadReplacingContent(from:)`），
/// 旧条件的在途结果与下一页都不会并入。`reset` 与账户范围变化把条件恢复为默认。工具栏控件的宿主在 App，只绑定这里
/// 的状态。
@MainActor
@Observable
public final class WatchLaterSession {
    /// 工具栏搜索框的文字；清空（只剩空白）且已按关键词过滤时恢复全部，提交前不影响列表。
    public var searchDraft = "" {
        didSet {
            guard searchDraft != oldValue,
                Self.normalized(searchDraft).isEmpty,
                !appliedCriteria.keyword.isEmpty
            else { return }
            apply(keyword: "")
        }
    }
    /// 排序菜单与筛选弹窗编辑的选择；排序立即生效，筛选在弹窗“应用”后经 `applyFilters` 生效。
    public var filterSelection = WatchLaterFilterSelection()
    /// 当前列表使用的完整条件。
    public private(set) var appliedCriteria = WatchLaterCriteria()

    @ObservationIgnored private let model: WatchLaterViewModel

    public init(model: WatchLaterViewModel) {
        self.model = model
    }

    /// 有筛选或关键词在起作用（排序不算）；结果为空时界面据此给出“清除筛选”。
    public var narrowsResults: Bool {
        appliedCriteria.narrowsResults
    }

    /// 提交规范化后的草稿作为关键词；与已应用的关键词相同时不重新加载。
    public func submitSearch() {
        let keyword = Self.normalized(searchDraft)
        guard keyword != appliedCriteria.keyword else { return }
        apply(keyword: keyword)
    }

    /// 排序菜单已把 `filterSelection.order` 设为 `order`。
    public func selectOrder(_ order: WatchLaterOrder) {
        guard order != appliedCriteria.order else { return }
        replaceCriteria(order: order)
    }

    /// 筛选弹窗“应用”；自定义日期不合法时不生效（弹窗已禁用应用按钮）。
    ///
    /// 相对时间按此刻解析并冻结。
    public func applyFilters(_ selection: WatchLaterFilterSelection) {
        // 不用 `try?`：它会把“不限加入时间”的 nil 与解析失败压成同一个 nil。
        let addedTime: WatchLaterAddedTimeRange?
        do {
            addedTime = try selection.resolvedAddedTime()
        } catch {
            return
        }
        filterSelection = selection
        replaceCriteria(
            progress: selection.progress,
            addedTime: .some(addedTime),
            duration: selection.duration
        )
    }

    /// 清除进度、加入时间、时长筛选与关键词，保留排序。
    public func clearFilters() {
        filterSelection.resetFilters()
        let cleared = WatchLaterCriteria(order: appliedCriteria.order)
        let changed = cleared != appliedCriteria
        // 先换掉已应用的条件再清空草稿：草稿的 didSet 看到关键词已空就不会再单独触发一次加载。
        appliedCriteria = cleared
        searchDraft = ""
        guard changed else { return }
        model.reloadReplacingContent(from: WatchLaterRequest(criteria: cleared))
    }

    /// 关窗、登出与换号：条件恢复默认，并丢弃列表内容（不发请求）。
    public func reset() {
        resetCriteria()
        model.reset()
    }

    /// 窗口账户范围变化：条件恢复默认，再交给列表丢弃上一账户的内容并按需重新加载。
    public func synchronizeAuthenticationSession(
        scope: AccountSessionScope,
        isCurrentRoute: Bool
    ) {
        resetCriteria()
        model.synchronizeAuthenticationSession(scope: scope, isCurrentRoute: isCurrentRoute)
    }

    private func resetCriteria() {
        filterSelection = WatchLaterFilterSelection()
        appliedCriteria = WatchLaterCriteria()
        searchDraft = ""
        model.replaceFirstPageCursor(WatchLaterRequest(criteria: appliedCriteria))
    }

    private func apply(keyword: String) {
        replaceCriteria(keyword: keyword)
    }

    /// 以已应用条件为底替换给出的部分，条件确有变化时从新条件的第一页重新加载。
    private func replaceCriteria(
        order: WatchLaterOrder? = nil,
        progress: WatchLaterProgressFilter? = nil,
        addedTime: WatchLaterAddedTimeRange?? = nil,
        duration: VideoDurationFilter? = nil,
        keyword: String? = nil
    ) {
        let criteria = WatchLaterCriteria(
            order: order ?? appliedCriteria.order,
            progress: progress ?? appliedCriteria.progress,
            addedTime: addedTime ?? appliedCriteria.addedTime,
            duration: duration ?? appliedCriteria.duration,
            keyword: keyword ?? appliedCriteria.keyword
        )
        guard criteria != appliedCriteria else { return }
        appliedCriteria = criteria
        model.reloadReplacingContent(from: WatchLaterRequest(criteria: criteria))
    }

    private static func normalized(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
