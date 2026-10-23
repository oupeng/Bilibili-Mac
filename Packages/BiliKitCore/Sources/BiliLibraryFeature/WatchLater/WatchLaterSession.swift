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

    /// 按此刻与当前日历把加入时间解析为区间；无法给出区间（自定义的开始日晚于结束日、早于 1970 年等）时抛出
    /// `DateRangeFilterError`。
    ///
    /// 弹窗据此禁用“应用”，会话在每次开始新的分页会话时调用。
    public func resolvedAddedTime() throws -> WatchLaterAddedTimeRange? {
        try WatchLaterAddedTimeRangeResolver.resolve(
            filter: addedTime,
            customStart: customStart,
            customEnd: customEnd,
            now: Date(),
            calendar: .current
        )
    }
}

/// 稍后再看来源的会话：工具栏的搜索草稿、排序与筛选选择、已应用的条件，以及条件到列表请求的映射。
///
/// 每个窗口一份，由 App 的窗口组装构造。拥有草稿、选择与已应用的条件（只在窗口内存里，不持久化，见
/// SECURITY-MODEL §6）；不拥有请求、分页、generation 与复核（`WatchLaterViewModel`）。已应用的加入时间保存为未解析的
/// 选项，构造时把第一页请求的求值交给列表（`LibraryVideoListModel.firstPageCursor`）：每次开始新的分页会话（首次
/// 加载、应用条件、刷新、复核后重载）都按此刻重新解析，翻页沿用游标里冻结的区间。条件变化（排序、应用筛选、提交或
/// 清空关键词）从空列表重新加载（`reloadReplacingContent()`），旧条件的在途结果与下一页都不会并入；刷新时解析出的
/// 区间变了同样清空重载，没变则原地刷新。`reset` 与账户范围变化把条件恢复为默认。工具栏控件的宿主在 App，只绑定
/// 这里的状态。
@MainActor
@Observable
public final class WatchLaterSession {
    /// 工具栏搜索框的文字；清空（只剩空白）且已按关键词过滤时恢复全部，提交前不影响列表（规则在
    /// `LibrarySearchKeyword`）。
    public var searchDraft: String {
        get { keyword.draft }
        set {
            if keyword.updateDraft(newValue) {
                model.reloadReplacingContent()
            }
        }
    }
    /// 排序菜单与筛选弹窗编辑的选择；排序立即生效，筛选在弹窗“应用”后经 `applyFilters` 生效。
    public var filterSelection = WatchLaterFilterSelection()
    /// 当前列表使用的排序与筛选（加入时间是未解析的选项）。
    public private(set) var appliedFilters = WatchLaterFilterSelection()
    /// 当前列表使用的关键词；空串表示不按关键词过滤。
    public var appliedKeyword: String {
        keyword.applied
    }

    private var keyword = LibrarySearchKeyword()

    @ObservationIgnored private let model: WatchLaterViewModel

    public init(model: WatchLaterViewModel) {
        self.model = model
        model.firstPageCursor = { [weak self] in self?.firstPageRequest() }
    }

    /// 有筛选或关键词在起作用（排序不算）；结果为空时界面据此给出“清除筛选”。
    public var narrowsResults: Bool {
        appliedFilters.activeFilterCount > 0 || !appliedKeyword.isEmpty
    }

    /// 工具栏刷新：按此刻重新解析条件，区间不变时原地刷新，变了就清空重载（见 `LibraryVideoListModel.reload`）。
    public func refresh() {
        model.reload()
    }

    /// 提交规范化后的草稿作为关键词；与已应用的关键词相同时不重新加载。
    public func submitSearch() {
        guard keyword.submit() else { return }
        model.reloadReplacingContent()
    }

    /// 排序菜单已把 `filterSelection.order` 设为 `order`。
    public func selectOrder(_ order: WatchLaterOrder) {
        guard order != appliedFilters.order else { return }
        appliedFilters.order = order
        model.reloadReplacingContent()
    }

    /// 筛选弹窗“应用”；加入时间无法解析时不生效（弹窗已禁用应用按钮）。
    public func applyFilters(_ selection: WatchLaterFilterSelection) {
        do {
            _ = try selection.resolvedAddedTime()
        } catch {
            return
        }
        filterSelection = selection
        appliedFilters = selection
        model.reloadReplacingContent()
    }

    /// 清除进度、加入时间、时长筛选与关键词，保留排序。
    public func clearFilters() {
        filterSelection.resetFilters()
        var cleared = appliedFilters
        cleared.resetFilters()
        let filtersChanged = cleared != appliedFilters
        appliedFilters = cleared
        let keywordChanged = keyword.clear()
        guard filtersChanged || keywordChanged else { return }
        model.reloadReplacingContent()
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

    /// 已应用条件在此刻的第一页请求；加入时间无法解析时为 nil，列表据此按无效请求失败。
    func firstPageRequest() -> WatchLaterRequest? {
        let addedTime: WatchLaterAddedTimeRange?
        do {
            addedTime = try appliedFilters.resolvedAddedTime()
        } catch {
            return nil
        }
        return WatchLaterRequest(
            criteria: WatchLaterCriteria(
                order: appliedFilters.order,
                progress: appliedFilters.progress,
                addedTime: addedTime,
                duration: appliedFilters.duration,
                keyword: appliedKeyword
            )
        )
    }

    private func resetCriteria() {
        filterSelection = WatchLaterFilterSelection()
        appliedFilters = WatchLaterFilterSelection()
        keyword = LibrarySearchKeyword()
    }
}
