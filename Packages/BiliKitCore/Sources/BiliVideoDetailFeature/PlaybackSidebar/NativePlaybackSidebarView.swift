import AppKit
import BiliApplication
import BiliModels
import SwiftUI

/// 播放态侧栏：把视频与评论 ViewModel 投影成原生集合视图的呈现，用户操作转回 ViewModel 或 App 给的回调。
///
/// AppKit 集合视图的理由见 ARCHITECTURE「原生 AppKit 集合视图」；图片经 `VideoDetailImageLoading` 注入。
public struct NativePlaybackSidebarView: View {
    let model: VideoViewModel
    let commentsModel: PlaybackCommentsViewModel?
    let commentAssetURLResolver: CommentAssetURLResolver
    let commentImagePipeline: any VideoDetailImageLoading
    let onRetry: () -> Void
    let onSelectPlayback: (String, Int64?) -> Void
    let onOpenCommentLink: (CommentLinkTarget) -> Void
    let onOpenCommentPictures: (NativePlaybackCommentPictureGallery) -> Void
    /// 点击 UP 主行或评论作者（头像与昵称）进入空间；nil 时不显示入口。
    var onOpenUploaderSpace: ((VideoOwner) -> Void)?
    /// 被空间层盖住时真正隐藏原生视图：SwiftUI 的透明度与 hit testing 管不到 AppKit 的
    /// cursor rect 与 tracking area，只设透明会让评论正文继续改变指针形状。
    var isObscured: Bool

    public init(
        model: VideoViewModel,
        commentsModel: PlaybackCommentsViewModel?,
        commentAssetURLResolver: @escaping CommentAssetURLResolver,
        commentImagePipeline: any VideoDetailImageLoading,
        onRetry: @escaping () -> Void,
        onSelectPlayback: @escaping (String, Int64?) -> Void,
        onOpenCommentLink: @escaping (CommentLinkTarget) -> Void,
        onOpenCommentPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenUploaderSpace: ((VideoOwner) -> Void)? = nil,
        isObscured: Bool = false
    ) {
        self.model = model
        self.commentsModel = commentsModel
        self.commentAssetURLResolver = commentAssetURLResolver
        self.commentImagePipeline = commentImagePipeline
        self.onRetry = onRetry
        self.onSelectPlayback = onSelectPlayback
        self.onOpenCommentLink = onOpenCommentLink
        self.onOpenCommentPictures = onOpenCommentPictures
        self.onOpenUploaderSpace = onOpenUploaderSpace
        self.isObscured = isObscured
    }

    public var body: some View {
        let presentation = presentation
        let openUserSpace = openUserSpace
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
                openCommentLink: { [onOpenCommentLink] target in
                    NativePlaybackCommentAuthorSpace.openLink(
                        target,
                        openSpace: openUserSpace,
                        otherwise: onOpenCommentLink
                    )
                },
                openCommentPictures: onOpenCommentPictures,
                openUploaderSpace: onOpenUploaderSpace.map { open in
                    {
                        guard let owner = model.presentedContext?.detail.owner else { return }
                        open(owner)
                    }
                },
                openCommentAuthorSpace: openUserSpace
            )
        )
        .overlay {
            NativePlaybackSidebarOverlayView(overlay: presentation.overlay, retry: retry)
        }
        .navigationTitle(VideoDetailFeatureStrings.localized("观看辅助"))
    }

    /// 评论作者与正文 @ 用户进入空间的同一入口；没有空间功能时为 nil。
    private var openUserSpace: ((CommentAuthor) -> Void)? {
        onOpenUploaderSpace.map { open in
            { [commentAssetURLResolver] user in
                guard
                    let owner = NativePlaybackCommentAuthorSpace.owner(
                        for: user,
                        resolveAvatar: commentAssetURLResolver
                    )
                else { return }
                open(owner)
            }
        }
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
                summaryLinks: context.detail.summaryLinks,
                selection: selectionProjection(context),
                comments: commentsPresentation(context),
                timestampLimitSeconds: timestampLimitSeconds
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

    /// 播放器就绪的分 P 的可跳转时长；加载、切换分 P 或失败时为 nil，时间戳按普通文字显示。
    private var timestampLimitSeconds: Int? {
        guard case .ready(let context) = model.state else { return nil }
        return context.seekableDurationSeconds
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
    let commentImagePipeline: any VideoDetailImageLoading
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
        topButtonLabel: VideoDetailFeatureStrings.localized("返回顶部")
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
                Button(VideoDetailFeatureStrings.localized("重试"), action: retry)
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
