import BiliApplication
import BiliUI
import Foundation
import SwiftUI

struct VideoDetailView<PlayerContent: View, RelatedContent: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    let context: VideoContext
    let isPreparingPlayback: Bool
    let danmakuModel: DanmakuControlsViewModel
    let relatedVideoState: RelatedVideoState
    let onSelectRelatedVideo: (String) -> Void
    let onRetryRelatedVideos: () -> Void
    let playerContent: () -> PlayerContent
    let makeRelatedContent:
        (
            String,
            [RelatedVideoCardPresentation],
            @escaping (String) -> Void
        ) -> RelatedContent

    var body: some View {
        PlaybackDetailLayout {
            player
        } related: {
            RelatedVideoShelf(
                state: shelfState,
                contentIdentity: context.detail.bvid,
                onSelect: onSelectRelatedVideo,
                onRetry: onRetryRelatedVideos,
                makeLoadedContent: makeRelatedContent
            )
        }
        .navigationTitle(context.detail.title)
        .navigationSubtitle(toolbarSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DanmakuControlsView(model: danmakuModel)
            }
        }
    }

    private var shelfState: RelatedVideoShelfState {
        switch relatedVideoState {
        case .idle, .loading:
            .loading
        case .loaded(let bvid, let videos) where bvid == context.detail.bvid:
            .loaded(
                videos.map { RelatedVideoCardPresentation(video: $0, locale: locale) }
            )
        case .empty(let bvid) where bvid == context.detail.bvid:
            .empty
        case .failed(let bvid, _) where bvid == context.detail.bvid:
            .failure
        case .loaded, .empty, .failed:
            .loading
        }
    }

    /// 工具栏副标题：播放 · 弹幕 · 发布时间，有访问限制时接上充电／试看提示。
    private var toolbarSubtitle: String {
        let statistics = context.detail.statistics
        let viewCount = VideoMetadataFormatting.compactCount(statistics.viewCount, locale: locale)
        let danmakuCount = VideoMetadataFormatting.compactCount(
            statistics.danmakuCount,
            locale: locale
        )
        return [
            BrowseFeatureStrings.localized("\(viewCount)播放", locale: locale),
            BrowseFeatureStrings.localized("\(danmakuCount)弹幕", locale: locale),
            VideoMetadataFormatting.fullPublishedDate(context.detail.publishedAt, locale: locale),
            accessNotice
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessNotice: String? {
        switch context.accessNotice {
        case .none:
            return nil
        case .upowerExclusive:
            return BrowseFeatureStrings.localized("充电专属", locale: locale)
        case .upowerPreview(let previewDurationSeconds, let fullDurationSeconds):
            let preview = VideoDurationFormatting.string(
                seconds: previewDurationSeconds,
                locale: locale
            )
            let full = VideoDurationFormatting.string(
                seconds: fullDurationSeconds,
                locale: locale
            )
            let durationNotice = String(
                format: BrowseFeatureStrings.localized(
                    "可试看至 %@ / 完整视频 %@",
                    locale: locale
                ),
                locale: locale,
                preview,
                full
            )
            return [
                BrowseFeatureStrings.localized("充电专属", locale: locale),
                durationNotice
            ].joined(separator: " · ")
        }
    }

    private var player: some View {
        ZStack {
            playerContent()

            if isPreparingPlayback {
                ZStack {
                    Rectangle()
                        .fill(.black)
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                            .tint(.white)
                        Text(BrowseFeatureStrings.localized("正在准备播放…", locale: locale))
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .environment(\.colorScheme, .dark)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(BrowseFeatureStrings.localized("正在准备播放", locale: locale))
                }
                .transition(
                    .asymmetric(
                        insertion: .identity,
                        removal: .opacity
                    )
                )
            }
        }
        .animation(
            LoadingStateTransition.animation(reduceMotion: reduceMotion),
            value: isPreparingPlayback
        )
        .background(.black)
    }
}
