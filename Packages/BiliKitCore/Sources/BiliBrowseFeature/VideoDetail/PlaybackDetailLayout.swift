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
                // 加载阶段切换带动画时，新建的 AVPlayerView 会从初始 frame 动画到最终位置，
                // 看起来像“飞入”。视频区只随窗口即时变化，不参与任何布局动画。
                .transaction { $0.animation = nil }
                .aspectRatio(PlaybackPageLayout.playerAspectRatio, contentMode: .fit)
                .padding(.horizontal, PlaybackPageLayout.horizontalContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            related
        }
        .padding(.top, PlaybackPageLayout.verticalContentPadding)
        .padding(.bottom, PlaybackPageLayout.relatedBottomPadding)
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
