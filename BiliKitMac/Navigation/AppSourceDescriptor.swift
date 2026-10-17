import BiliBrowseFeature
import BiliLibraryFeature
import Foundation

/// 侧栏一个平级来源的描述：标题、图标，以及窗口在来源边界上对它做的事。
///
/// 只保存读取与动作闭包，不拥有模型；模型归 `AppWindowOwner`。侧栏行、刷新回顶、离开来源时的停用、关窗与
/// 其他窗口换号时的清理都遍历 `AppSources`，新增来源时这些地方不需要各自再登记一次。根视图的构造
/// （`AppShellView.selectedSourceRoot`）与 Browse 工作集的激活（`AppRootView.browseActivation`）依赖各来源
/// 自己的类型，仍是 `AppTab` 上的穷尽 switch，漏写由编译器报。
@MainActor
struct AppSourceDescriptor: Identifiable {
    let id: AppTab
    /// 侧栏行与来源页导航标题共用。
    let title: LocalizedStringResource
    let systemImage: String
    /// 内容只属于当前账户（只在登录后读取）。
    ///
    /// 其他窗口换号时，本窗口在自己的复核结束前就先 `reset`，不让上一账户的内容在复核期间继续显示。
    let requiresAccount: Bool
    /// 内容被整体替换的代次；`AppShellView` 在它前进时只把这个来源的网格滚回顶部。
    ///
    /// 按各来源现有语义透传：推荐、热门与搜索只在原地刷新成功时前进，历史每次加载成功（含首次加载）都前进。
    let refreshGeneration: @MainActor () -> UInt64
    /// 从本来源切到另一个来源时调用一次；推荐、热门与搜索的停用由 Browse 激活（`AppRootView.browseActivation`）
    /// 统一承担，这里不动作。
    let deactivate: @MainActor () -> Void
    /// 取消本来源自己的请求并丢弃自己的内容（搜索的草稿与热搜、观看历史）。
    ///
    /// 由 `AppSources` 调用：关窗时对所有来源，其他窗口换号时只对 `requiresAccount` 的来源。推荐、热门与搜索
    /// 共用的 Browse 工作集不属于某一个来源，不在这里，由 `AppSources.resetForWindowClosure` 整体丢弃一次。
    let reset: @MainActor () -> Void
}

/// 一个窗口的全部来源描述，按侧栏顺序排列；由 `AppWindowOwner` 构造一次。
///
/// 构造是对 `AppTab.allCases` 的穷尽 switch：新增一个 `AppTab` 必须在这里给出完整描述，否则不能编译，因此每个
/// `AppTab` 恰好有一份描述，按 tab 取描述不会落空。
@MainActor
struct AppSources {
    let ordered: [AppSourceDescriptor]
    /// 推荐、热门与搜索共用的 Browse 工作集；只在关窗时整体丢弃。
    private let resetBrowseWorksets: @MainActor () -> Void

    init(
        browseModel: BrowseViewModel,
        historyModel: WatchHistoryViewModel,
        trendingSearchModel: TrendingSearchViewModel?
    ) {
        resetBrowseWorksets = { browseModel.reset() }
        ordered = AppTab.allCases.map { tab in
            switch tab {
            case .search:
                AppSourceDescriptor(
                    id: tab,
                    title: "搜索",
                    systemImage: "magnifyingglass",
                    requiresAccount: false,
                    refreshGeneration: { browseModel.successfulRefreshGeneration(for: .search) },
                    deactivate: {},
                    reset: {
                        trendingSearchModel?.reset()
                    }
                )
            case .home:
                AppSourceDescriptor(
                    id: tab,
                    title: "首页",
                    systemImage: "house",
                    requiresAccount: false,
                    refreshGeneration: {
                        browseModel.successfulRefreshGeneration(for: .recommendation)
                    },
                    deactivate: {},
                    // 推荐与热门只有共用的 Browse 工作集，没有自己的内容。
                    reset: {}
                )
            case .popular:
                AppSourceDescriptor(
                    id: tab,
                    title: "热门",
                    systemImage: "flame",
                    requiresAccount: false,
                    refreshGeneration: { browseModel.successfulRefreshGeneration(for: .popular) },
                    deactivate: {},
                    // 推荐与热门只有共用的 Browse 工作集，没有自己的内容。
                    reset: {}
                )
            case .history:
                AppSourceDescriptor(
                    id: tab,
                    title: "观看历史",
                    systemImage: "clock.arrow.circlepath",
                    requiresAccount: true,
                    refreshGeneration: { historyModel.successfulReloadGeneration },
                    deactivate: historyModel.deactivateRoute,
                    reset: historyModel.reset
                )
            }
        }
    }

    /// 关窗：每个来源丢弃自己的内容，再整体丢弃一次 Browse 工作集。
    func resetForWindowClosure() {
        for source in ordered {
            source.reset()
        }
        resetBrowseWorksets()
    }

    /// 其他窗口换号、本窗口复核前：只丢弃要求账户的来源的内容，不让上一账户的内容在复核期间继续显示。
    func resetAccountContent() {
        for source in ordered where source.requiresAccount {
            source.reset()
        }
    }

    subscript(tab: AppTab) -> AppSourceDescriptor {
        guard let descriptor = ordered.first(where: { $0.id == tab }) else {
            preconditionFailure("AppSources 对每个 AppTab 都构造了描述")
        }
        return descriptor
    }
}
