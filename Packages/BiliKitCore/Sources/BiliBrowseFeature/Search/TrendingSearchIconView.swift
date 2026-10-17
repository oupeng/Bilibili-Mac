import CoreGraphics
import SwiftUI

/// 热搜词旁的小图标（如“热”“新”）；经注入的 `TrendingSearchIconLoading` 加载，加载失败时不占位。
///
/// 只持有当前地址已到达的图；`.task(id:)` 随地址变化取消旧加载，旧地址的结果按地址比对后不显示。
struct TrendingSearchIconView: View {
    let url: URL
    let iconLoader: any TrendingSearchIconLoading
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        // 零尺寸占位让 `.task` 在图片到达前就能运行；空内容上的 modifier 不会出现。
        ZStack {
            Color.clear
                .frame(width: 0, height: 0)
            if let loaded, loaded.url == url {
                Image(decorative: loaded.image, scale: 2)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: url) {
            if let cached = iconLoader.cachedTrendingSearchIcon(for: url) {
                loaded = (url, cached)
                return
            }
            guard let image = await iconLoader.trendingSearchIcon(for: url),
                !Task.isCancelled
            else { return }
            loaded = (url, image)
        }
    }
}
