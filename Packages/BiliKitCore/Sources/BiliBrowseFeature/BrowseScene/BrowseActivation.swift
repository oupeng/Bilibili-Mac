import BiliApplication

/// 当前来源要求 `BrowseViewModel` 激活的工作集；App 由当前来源（与搜索会话）得出，作为 `.task(id:)` 的 identity。
public enum BrowseActivation: Hashable, Sendable {
    case recommendation
    case popular
    /// 搜索页；还没有提交搜索时为 nil，此时停用 Browse 路由、显示起始页。
    case search(criteria: VideoSearchCriteria?)
    /// 当前来源不由 Browse 承担（观看历史）。
    case inactive
}

extension BrowseViewModel {
    /// 激活对应的工作集并等待当前模型任务；任务所有权与取消仍由本模型管理。
    public func activate(_ activation: BrowseActivation) async {
        switch activation {
        case .recommendation:
            activateRecommendation()
            await waitForCurrentTask()
        case .popular:
            activatePopular(pageSize: Self.popularPageSize)
            await waitForCurrentTask()
        case .search(nil), .inactive:
            deactivateRoute()
        case .search(.some(let criteria)):
            activateSearch(criteria)
            await waitForCurrentTask()
        }
    }
}
