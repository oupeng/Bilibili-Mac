import SwiftUI

/// 首载骨架：列数、卡片尺寸、间距、内容边距与占位卡片数都取自生产网格的 `VideoCardGridGeometry`。
///
/// 卡片数按可见尺寸计算（`placeholderCount(for:expectedItemCount:)`），窗口缩放时跟着增减；来源知道本页
/// 条数时不超过它，否则铺满可见区域。骨架禁用滚动，只画视野内的卡片。
package struct VideoCardGridSkeleton: View {
    private let loadingLabel: String
    private let expectedItemCount: Int?

    /// `expectedItemCount` 是来源已知的本页条数（收藏夹按夹的总数与页码、稍后再看按同条件上次的总数），不知道时为 nil。
    package init(loadingLabel: String, expectedItemCount: Int? = nil) {
        self.loadingLabel = loadingLabel
        self.expectedItemCount = expectedItemCount
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
                        0..<VideoCardGridGeometry.placeholderCount(
                            for: geometry.size,
                            expectedItemCount: expectedItemCount
                        ),
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
