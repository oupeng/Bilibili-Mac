import SwiftUI

/// 首载骨架：列数、卡片尺寸、间距、内容边距与占位卡片数都取自生产网格的 `VideoCardGridGeometry`。
///
/// 卡片数按可见尺寸计算（`placeholderCount(for:)`），窗口缩放时跟着增减，任何窗口都铺满可见区域；
/// 骨架禁用滚动，只画视野内的卡片。
package struct VideoCardGridSkeleton: View {
    private let loadingLabel: String

    package init(loadingLabel: String) {
        self.loadingLabel = loadingLabel
    }

    package var body: some View {
        GeometryReader { geometry in
            let itemSize = VideoCardGridGeometry.itemSize(for: geometry.size.width)
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .fixed(itemSize.width),
                            spacing: VideoCardGridGeometry.horizontalSpacing
                        ),
                        count: VideoCardGridGeometry.columnCount(for: geometry.size.width)
                    ),
                    alignment: .leading,
                    spacing: VideoCardGridGeometry.verticalSpacing
                ) {
                    ForEach(
                        0..<VideoCardGridGeometry.placeholderCount(for: geometry.size),
                        id: \.self
                    ) { _ in
                        VideoCardSkeleton(size: itemSize, showsAvatar: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, VideoCardGridGeometry.topContentPadding)
                .padding([.horizontal, .bottom], VideoCardGridGeometry.contentPadding)
            }
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadingLabel)
    }
}
