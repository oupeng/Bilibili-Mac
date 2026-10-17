import BiliVideoCollectionUI
import SwiftUI

/// 播放页主区下方的相关推荐横排：把相关推荐投影映射为共享卡片，经卡片取图 port 加载封面。
public struct RelatedNativeShelfView: View {
    let contentIdentity: String
    let presentations: [RelatedVideoCardPresentation]
    let imagePipeline: any NativeVideoImageLoading
    let onSelect: (String) -> Void

    public init(
        contentIdentity: String,
        presentations: [RelatedVideoCardPresentation],
        imagePipeline: any NativeVideoImageLoading,
        onSelect: @escaping (String) -> Void
    ) {
        self.contentIdentity = contentIdentity
        self.presentations = presentations
        self.imagePipeline = imagePipeline
        self.onSelect = onSelect
    }

    public var body: some View {
        NativeVideoShelfView(
            contentIdentity: contentIdentity,
            items: Self.makePresentations(presentations),
            imagePipeline: imagePipeline,
            onSelect: onSelect
        )
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    static func makePresentations(
        _ presentations: [RelatedVideoCardPresentation]
    ) -> [NativeVideoCardPresentation] {
        presentations.map { presentation in
            NativeVideoCardPresentation(
                id: presentation.bvid,
                title: presentation.title,
                coverURL: presentation.coverURL,
                avatarURL: nil,
                showsAvatar: false,
                coverMetrics: [
                    NativeVideoCardMetric(
                        text: presentation.viewCountText,
                        systemImage: "play.fill"
                    ),
                    NativeVideoCardMetric(
                        text: presentation.danmakuCountText,
                        systemImage: "text.bubble.fill"
                    )
                ],
                coverTrailingText: presentation.durationText,
                footerLeadingText: presentation.ownerName,
                accessibilityLabel: presentation.accessibilityLabel,
                accessibilityHelp: VideoDetailFeatureStrings.localized("播放并替换当前视频")
            )
        }
    }
}
