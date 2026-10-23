import BiliApplication
import BiliLibraryFeature
import Foundation
import SwiftUI

/// 收藏夹工具栏的排序菜单：只编辑 `FavoriteFolderViewModel` 的排序选择，选中即经 `selectOrder` 生效。
///
/// 菜单形态与搜索、稍后再看共用（`ToolbarSortMenu`）；由收藏夹页面放进自己 `.toolbar` 的 primaryAction 组、排在刷新之前。
/// 不做分区筛选与“全部收藏夹”搜索。
struct FavoritesToolbarControls: View {
    @Environment(\.locale) private var locale
    @Bindable var model: FavoriteFolderViewModel

    var body: some View {
        ToolbarSortMenu(
            options: FavoriteFolderOrder.allCases,
            selection: $model.orderSelection,
            title: { $0.localizedTitle(locale: locale) },
            help: AppStrings.localized(
                "收藏夹排序：\(model.orderSelection.localizedTitle(locale: locale))",
                locale: locale
            ),
            onSelect: model.selectOrder
        )
    }
}

extension FavoriteFolderOrder {
    func localizedTitle(locale: Locale = .current) -> String {
        switch self {
        case .recentlyFavorited: AppStrings.localized("最近收藏", locale: locale)
        case .mostPlayed: AppStrings.localized("最多播放", locale: locale)
        case .recentlyPublished: AppStrings.localized("最近投稿", locale: locale)
        }
    }
}
