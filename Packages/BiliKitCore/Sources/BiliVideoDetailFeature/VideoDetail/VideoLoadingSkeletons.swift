import BiliUI
import SwiftUI

/// 详情尚未到达时的播放页骨架：与真实页面共用 `PlaybackDetailLayout`，读屏只读加载说明。
struct VideoDetailSkeleton: View {
    let loadingLabel: String

    var body: some View {
        PlaybackDetailLayout {
            Rectangle()
                .fill(.black)
                .overlay {
                    PlayerLoadingIndicator()
                }
        } related: {
            RelatedVideoShelf<EmptyView>(
                state: .loading,
                contentIdentity: "loading",
                onSelect: { _ in },
                onRetry: {},
                makeLoadedContent: { _, _, _ in EmptyView() }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}
