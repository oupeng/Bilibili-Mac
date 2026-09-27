import BiliUI
import SwiftUI

/// 播放页主区：视频取剩余空间里最大的 16:9，下方是固定高度的相关推荐；主区不滚动。
///
/// 标题与数据在工具栏，弹幕设置在工具栏弹出面板，简介、选集与评论在侧栏。真实页面与加载骨架
/// 共用这一份布局，加载完成时视频与推荐位置不跳动。
struct PlaybackDetailLayout<Player: View, Related: View>: View {
    private let player: Player
    private let related: Related

    init(
        @ViewBuilder player: () -> Player,
        @ViewBuilder related: () -> Related
    ) {
        self.player = player()
        self.related = related()
    }

    var body: some View {
        VStack(spacing: PlaybackPageLayout.sectionSpacing) {
            player
                .aspectRatio(PlaybackPageLayout.playerAspectRatio, contentMode: .fit)
                .padding(.horizontal, PlaybackPageLayout.horizontalContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            related
        }
        .padding(.top, PlaybackPageLayout.verticalContentPadding)
        .padding(.bottom, PlaybackPageLayout.relatedBottomPadding)
        // 骨架与内容共用这套几何，加载阶段切换只在外层交叉淡化，布局内部不参与任何动画：
        // 新建的 AppKit 视图（播放器、推荐横排）否则会从初始 frame 动画到最终位置，看起来像“飞入”。
        .transaction { $0.animation = nil }
    }
}

enum PlaybackPageLayout {
    static let horizontalContentPadding: CGFloat = 40
    /// 工具栏到视频、推荐卡片到窗口底边的距离。
    static let verticalContentPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 18
    static let playerAspectRatio: CGFloat = 16.0 / 9.0
    /// 横排卡片下方已有可视区留白，页面只补足剩余部分。
    static let relatedBottomPadding = max(
        0,
        verticalContentPadding - VideoCardShelfGeometry.bottomInset
    )
}
