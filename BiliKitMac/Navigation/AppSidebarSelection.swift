/// 导航侧栏 `List` 的选择值：一个平级来源的行，或一个来源在侧栏提供的多行之一。
///
/// 每行用不同的值作 tag：同一来源的多行若共用来源的 tag，会同时高亮，键盘上下移动也会乱。值只由侧栏读写，
/// 来源本身仍是 `AppTab`（`AppNavigationCoordinator.selectedTab`），根视图、停用与账户语义照旧按 `AppTab` 穷尽 switch。
enum AppSidebarSelection: Hashable {
    /// 单行来源的行。
    case source(AppTab)
    /// 提供多行的来源（`AppSourceDescriptor.itemSelection` 非 nil）里的一行；`id` 由来源解释。
    case item(AppTab, id: Int64)
}

/// 提供多行的来源在侧栏上的选中读写：哪一行被选中、选中一行时交给来源。
///
/// 只保存闭包，不拥有状态；被选中的条目记在来源自己的模型里，侧栏重建（进入、退出播放）后由它恢复高亮。
@MainActor
struct AppSourceItemSelection {
    /// 来源当前选中的条目；没有时为 nil，侧栏按来源本身（`.source`）高亮，即不高亮任何一行。
    let selectedID: @MainActor () -> Int64?
    /// 用户在侧栏选中一行；在切换到该来源之前调用。
    let select: @MainActor (Int64) -> Void
}

extension AppSources {
    /// 侧栏此刻应高亮的值：提供多行的来源有选中条目时是那一行，其余是来源本身。
    func sidebarSelection(for tab: AppTab) -> AppSidebarSelection {
        if let id = self[tab].itemSelection?.selectedID() {
            return .item(tab, id: id)
        }
        return .source(tab)
    }

    /// 侧栏选中一行：多行来源先把条目交给来源，再切换到该来源（同一来源内换行不切换来源，不关闭播放与停用来源）。
    func select(_ selection: AppSidebarSelection, in coordinator: AppNavigationCoordinator) {
        switch selection {
        case .source(let tab):
            coordinator.selectedTab = tab
        case .item(let tab, let id):
            self[tab].itemSelection?.select(id)
            coordinator.selectedTab = tab
        }
    }
}
