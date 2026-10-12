import CoreGraphics
import SwiftUI

/// 热搜词旁的小图标（如“热”“新”）；经窗口共用的无凭据图片管线加载，加载失败时不占位。
struct TrendingSearchIconView: View {
    let url: URL
    let imagePipeline: NativeVideoImagePipeline
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
            if let cached = imagePipeline.cachedImage(for: url, variant: .trendingSearchIcon) {
                loaded = (url, cached)
                return
            }
            guard let result = await imagePipeline.image(for: url, variant: .trendingSearchIcon),
                !Task.isCancelled
            else { return }
            loaded = (url, result.image)
        }
    }
}
