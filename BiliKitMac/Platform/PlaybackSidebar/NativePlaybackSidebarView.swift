import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import SwiftUI

struct NativePlaybackSidebarView: View {
    let model: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    let onOpenCommentLink: (CommentLinkTarget) -> Void
    let onOpenCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    /// 点击 UP 主行或评论作者（头像与昵称）进入空间；nil 时不显示入口。
    var onOpenUploaderSpace: ((VideoOwner) -> Void)? = nil
    /// 被空间层盖住时真正隐藏原生视图：SwiftUI 的透明度与 hit testing 管不到 AppKit 的
    /// cursor rect 与 tracking area，只设透明会让评论正文继续改变指针形状。
    var isObscured = false

    var body: some View {
        let presentation = presentation
        NativePlaybackSidebarRepresentable(
            presentation: presentation,
            commentAssetURLResolver: commentAssetURLResolver,
            commentImagePipeline: commentImagePipeline,
            isObscured: isObscured,
            actions: NativePlaybackSidebarActions(
                selectEpisode: selectEpisode,
                selectPage: selectPage,
                retryPages: retryPages,
                selectCommentSort: { commentsModel?.selectSort($0) },
                retryComments: { commentsModel?.retryRoot() },
                loadNextComments: { commentsModel?.loadNextPage() },
                expandReplies: { commentsModel?.expandReplies(for: $0) },
                collapseReplies: { commentsModel?.collapseReplies(for: $0) },
                previousReplyPage: {
                    commentsModel?.showPreviousReplyPage(for: $0)
                },
                nextReplyPage: { commentsModel?.showNextReplyPage(for: $0) },
                retryReplies: { commentsModel?.retryReplies(for: $0) },
                openCommentLink: onOpenCommentLink,
                openCommentPictures: onOpenCommentPictures,
                openUploaderSpace: onOpenUploaderSpace.map { open in
                    {
                        guard let owner = model.presentedContext?.detail.owner else { return }
                        open(owner)
                    }
                },
                openCommentAuthorSpace: onOpenUploaderSpace.map { open in
                    { [commentAssetURLResolver] author in
                        guard
                            let owner = NativePlaybackCommentAuthorSpace.owner(
                                for: author,
                                resolveAvatar: commentAssetURLResolver
                            )
                        else { return }
                        open(owner)
                    }
                }
            )
        )
        .overlay {
            NativePlaybackSidebarOverlayView(overlay: presentation.overlay, retry: retry)
        }
        .navigationTitle("观看辅助")
    }

    private var presentation: NativePlaybackSidebarPresentation {
        let content = model.presentedContext.map { context in
            NativePlaybackSidebarContent(
                bvid: context.detail.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    profileState: model.uploaderProfileState
                ),
                summary: context.detail.summary,
                selection: selectionProjection(context),
                comments: commentsPresentation(context)
            )
        }
        return NativePlaybackSidebarPresentation(
            content: content,
            overlay: NativePlaybackSidebarOverlay.resolve(
                state: model.state,
                hasPresentedContent: content != nil
            )
        )
    }

    private func commentsPresentation(
        _ context: VideoContext
    ) -> NativePlaybackCommentsPresentation {
        guard let aid = context.detail.aid,
            commentsModel?.subject == .video(aid: aid)
        else {
            return NativePlaybackCommentsPresentation(model: nil)
        }
        return NativePlaybackCommentsPresentation(model: commentsModel)
    }

    private func selectionProjection(
        _ context: VideoContext
    ) -> PlaybackSelectionProjection {
        let episodes = context.detail.collection?.sections.flatMap(\.episodes) ?? []
        let pagesByEpisode = Dictionary(
            uniqueKeysWithValues: episodes.compactMap { episode in
                model.collectionEpisodePages(for: episode.id).map {
                    (episode.id, $0)
                }
            }
        )
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: model.selectedCollectionEpisode,
            requestedBVID: model.requestedSelectionBVID,
            requestedCID: model.requestedPreferredCID,
            presentedIdentity: model.presentedPlaybackIdentity,
            pageStates: model.collectionEpisodePageStates,
            pagesByEpisode: pagesByEpisode
        )
    }

    private func retry() {
        if case .failedPage = model.state {
            model.retry()
        } else {
            onRetry()
        }
    }

    private func selectEpisode(_ identity: VideoCollectionEpisodeIdentity) {
        guard
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.selectCollectionEpisode(episode) { bvid, preferredCID in
            onSelectPlayback(bvid, preferredCID)
        }
    }

    private func selectPage(_ bvid: String, _ cid: Int64) {
        onSelectPlayback(bvid, cid)
    }

    private func retryPages() {
        guard let identity = model.selectedCollectionEpisode,
            let episode = model.presentedContext?.detail.collection?.sections
                .flatMap(\.episodes)
                .first(where: { $0.id == identity })
        else { return }
        model.retryCollectionEpisodePages(episode)
    }
}

struct NativePlaybackSidebarActions {
    let selectEpisode: (VideoCollectionEpisodeIdentity) -> Void
    let selectPage: (String, Int64) -> Void
    let retryPages: () -> Void
    let selectCommentSort: (CommentSort) -> Void
    let retryComments: () -> Void
    let loadNextComments: () -> Void
    let expandReplies: (CommentID) -> Void
    let collapseReplies: (CommentID) -> Void
    let previousReplyPage: (CommentID) -> Void
    let nextReplyPage: (CommentID) -> Void
    let retryReplies: (CommentID) -> Void
    let openCommentLink: (CommentLinkTarget) -> Void
    let openCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    var openUploaderSpace: (() -> Void)? = nil
    var openCommentAuthorSpace: ((CommentAuthor) -> Void)? = nil
}

private struct NativePlaybackSidebarRepresentable: NSViewRepresentable {
    let presentation: NativePlaybackSidebarPresentation
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: NativeVideoImagePipeline
    let isObscured: Bool
    let actions: NativePlaybackSidebarActions

    func makeCoordinator() -> NativePlaybackSidebarController {
        NativePlaybackSidebarController(
            commentAssetURLResolver: commentAssetURLResolver,
            imagePipeline: commentImagePipeline
        )
    }

    func makeNSView(context: Context) -> NativePlaybackSidebarRootView {
        context.coordinator.update(presentation: presentation, actions: actions)
        context.coordinator.rootView.isHidden = isObscured
        return context.coordinator.rootView
    }

    func updateNSView(
        _ view: NativePlaybackSidebarRootView,
        context: Context
    ) {
        context.coordinator.update(presentation: presentation, actions: actions)
        if view.isHidden != isObscured {
            view.isHidden = isObscured
        }
    }

    static func dismantleNSView(
        _ view: NativePlaybackSidebarRootView,
        coordinator: NativePlaybackSidebarController
    ) {
        coordinator.tearDown()
    }
}

@MainActor
final class NativePlaybackSidebarRootView: NSView {
    let scrollView = NativeScrollToTopScrollView(
        topButtonLabel: AppStrings.localized("返回顶部")
    )
    var viewportSizeDidChange: ((CGSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        scrollView.verticalScrollElasticity = .automatic
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = true
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        scrollView.frame = bounds
        super.layout()
        viewportSizeDidChange?(scrollView.contentSize)
    }
}

/// 加载、失败与不可用状态盖在侧栏之上；`.none` 时不创建任何视图。
private struct NativePlaybackSidebarOverlayView: View {
    let overlay: NativePlaybackSidebarOverlay
    let retry: () -> Void

    var body: some View {
        switch overlay {
        case .none:
            EmptyView()
        case .loading(let label):
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(label)
        case .failure(let title, let message):
            ContentUnavailableView {
                Text(title)
            } description: {
                Text(message)
            } actions: {
                Button(AppStrings.localized("重试"), action: retry)
            }
        case .unavailable(let title, let message):
            ContentUnavailableView {
                Text(title)
            } description: {
                Text(message)
            }
        }
    }
}
