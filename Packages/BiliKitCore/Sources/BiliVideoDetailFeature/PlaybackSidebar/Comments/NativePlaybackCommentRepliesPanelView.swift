import AppKit
import BiliApplication
import BiliModels

/// 楼中楼面板：未展开时显示最多两条预览回复与“共 N 条回复”，展开后显示当前页回复与页码条、加载与重试。
///
/// 每次配置都按回复重建行视图（`resetRows` 先移除旧行）；回复状态与动作回调由条目传入，分页请求归 ViewModel。
/// 属于播放侧栏的原生 item，用 AppKit 的理由见 ARCHITECTURE「原生 AppKit 集合视图」的播放侧栏一条。
@MainActor
final class NativePlaybackCommentRepliesPanelView: NSView {
    nonisolated override var isFlipped: Bool { true }
    private let headerLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let expandButton = NSButton(title: "", target: nil, action: nil)
    private let collapseButton = NSButton(
        title: VideoDetailFeatureStrings.localized("收起"),
        target: nil,
        action: nil
    )
    private let retryButton = NSButton(
        title: VideoDetailFeatureStrings.localized("重试"),
        target: nil,
        action: nil
    )
    private let pager = NativePlaybackCommentReplyPager()
    private var replyRows: [NativePlaybackCommentRowView] = []
    private var thread: CommentThread?
    private var replyState: PlaybackCommentReplyState?
    private var textRenderer: NativePlaybackCommentTextRenderer?
    private var textScope: NativePlaybackCommentTextScope?
    private var onExpand: (() -> Void)?
    private var onCollapse: (() -> Void)?
    private var onShowPage: ((Int) -> Void)?
    private var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        headerLabel.font = .preferredFont(forTextStyle: .callout)
        headerLabel.textColor = .secondaryLabelColor
        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .secondaryLabelColor
        for button in [expandButton, collapseButton, retryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        expandButton.isBordered = false
        expandButton.contentTintColor = .controlAccentColor
        expandButton.alignment = .left
        expandButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: VideoDetailFeatureStrings.localized("展开")
        )
        expandButton.imagePosition = .imageLeading
        expandButton.imageScaling = .scaleProportionallyDown
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .controlAccentColor
        expandButton.target = self
        expandButton.action = #selector(expand)
        collapseButton.target = self
        collapseButton.action = #selector(collapse)
        retryButton.target = self
        retryButton.action = #selector(retry)
        for subview in [
            headerLabel,
            statusLabel,
            expandButton,
            collapseButton,
            retryButton,
            pager
        ] {
            addSubview(subview)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor =
            NSColor.quaternaryLabelColor
            .withAlphaComponent(0.12).cgColor
    }

    func configure(
        thread: CommentThread,
        replyState: PlaybackCommentReplyState?,
        textRenderer: NativePlaybackCommentTextRenderer,
        avatarLoader: NativePlaybackCommentAvatarLoader,
        pictureLoader: NativePlaybackCommentPictureLoader,
        textScope: NativePlaybackCommentTextScope,
        onTextLayoutChange: @escaping () -> Void,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void,
        onShowPage: @escaping (Int) -> Void,
        onRetry: @escaping () -> Void,
        onOpenLink: @escaping (CommentLinkTarget) -> Void,
        onOpenPictures: @escaping (NativePlaybackCommentPictureGallery) -> Void,
        onOpenAuthorSpace: ((CommentAuthor) -> Void)?
    ) {
        resetRows()
        self.thread = thread
        self.replyState = replyState
        self.textRenderer = textRenderer
        self.textScope = textScope
        self.onExpand = onExpand
        self.onCollapse = onCollapse
        self.onShowPage = onShowPage
        self.onRetry = onRetry
        guard case .available(let details) = thread.root.payload,
            details.replyCount > 0
        else {
            isHidden = true
            return
        }
        isHidden = false
        let expanded = replyState?.isExpanded == true
        let replies =
            expanded
            ? (replyState?.replies ?? [])
            : Array(thread.replyPreview.prefix(2))
        for reply in replies {
            let row = NativePlaybackCommentRowView()
            row.configure(
                comment: reply,
                isReply: true,
                textRenderer: textRenderer,
                avatarLoader: avatarLoader,
                pictureLoader: pictureLoader,
                textScope: textScope,
                onTextLayoutChange: onTextLayoutChange,
                onOpenLink: onOpenLink,
                onOpenPictures: onOpenPictures,
                onOpenAuthorSpace: onOpenAuthorSpace
            )
            addSubview(row)
            replyRows.append(row)
        }
        headerLabel.isHidden = !expanded
        collapseButton.isHidden = !expanded
        expandButton.isHidden = expanded
        retryButton.isHidden = true
        statusLabel.isHidden = true
        pager.isHidden = true
        if expanded {
            let total = replyState?.totalCount ?? 0
            headerLabel.stringValue =
                VideoDetailFeatureStrings.localized(
                    "共 \(CommentPresentationFormatting.compactCount(total > 0 ? total : details.replyCount)) 条回复"
                )
            if replyState?.isLoading == true {
                statusLabel.stringValue = VideoDetailFeatureStrings.localized("回复加载中…")
                statusLabel.isHidden = false
            } else if let error = replyState?.error {
                statusLabel.stringValue =
                    error.isRetryable
                    ? VideoDetailFeatureStrings.localized("回复加载失败") : error.nonRetryableDescription
                statusLabel.isHidden = false
                retryButton.isHidden = !error.isRetryable
            } else if let replyState {
                pager.isHidden = false
                pager.configure(
                    currentPage: replyState.pageNumber,
                    pageCount: NativePlaybackCommentReplyPager.pageCount(
                        for: replyState,
                        replyCount: details.replyCount
                    ),
                    onShowPage: { [weak self] in self?.onShowPage?($0) }
                )
            }
        } else {
            if expandButton.isHidden {
                expandButton.title = ""
                expandButton.setAccessibilityHelp(nil)
            } else {
                let count = CommentPresentationFormatting.compactCount(details.replyCount)
                expandButton.title = VideoDetailFeatureStrings.localized("共 \(count) 条回复")
                expandButton.setAccessibilityHelp(
                    VideoDetailFeatureStrings.localized("展开楼中楼，每页显示十条回复")
                )
            }
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let thread,
            case .available = thread.root.payload
        else { return }
        let padding = NativePlaybackCommentsItemMeasurement.replyPanelPadding
        let width = max(60, bounds.width - padding * 2)
        var y = padding
        let expanded = replyState?.isExpanded == true
        if expanded {
            headerLabel.frame = NSRect(x: padding, y: y, width: max(1, width - 62), height: 20)
            collapseButton.frame = NSRect(
                x: max(padding, bounds.width - padding - 54),
                y: y - 2,
                width: 54,
                height: 24
            )
            y += NativePlaybackCommentsItemMeasurement.replyHeaderRowHeight
        }
        for row in replyRows {
            guard let reply = row.commentForLayout else { continue }
            let height = NativePlaybackCommentsItemMeasurement.comment(
                reply,
                width: width,
                isReply: true,
                textRenderer: textRenderer,
                textScope: textScope
            )
            row.frame = NSRect(x: padding, y: y, width: width, height: height)
            y += height + NativePlaybackCommentsItemMeasurement.replyRowSpacing
        }
        if !replyRows.isEmpty { y -= NativePlaybackCommentsItemMeasurement.replyRowSpacing }
        if expanded {
            if replyState?.isLoading == true {
                statusLabel.frame = NSRect(
                    x: padding,
                    y: y,
                    width: width,
                    height: NativePlaybackCommentsItemMeasurement.replyStatusHeight
                )
            } else if replyState?.error != nil {
                statusLabel.frame = NSRect(
                    x: padding,
                    y: y + 5,
                    width: max(1, width - 72),
                    height: 22
                )
                retryButton.frame = NSRect(
                    x: max(padding, bounds.width - padding - 64),
                    y: y + 1,
                    width: 64,
                    height: 28
                )
            } else {
                if !replyRows.isEmpty { y += NativePlaybackCommentsItemMeasurement.replyFooterGap }
                pager.frame = NSRect(
                    x: padding,
                    y: y,
                    width: width,
                    height: NativePlaybackCommentsItemMeasurement.replyPagerHeight
                )
            }
        } else {
            if expandButton.isHidden {
                expandButton.frame = .zero
            } else {
                if !replyRows.isEmpty { y += 9 }
                expandButton.frame = NSRect(
                    x: padding,
                    y: y,
                    width: min(width, ceil(expandButton.fittingSize.width)),
                    height: 24
                )
            }
        }
    }

    func releaseOffscreenResources() {
        for row in replyRows { row.releaseOffscreenResources() }
    }

    func reset() {
        resetRows()
        thread = nil
        replyState = nil
        textRenderer = nil
        textScope = nil
        onExpand = nil
        onCollapse = nil
        onShowPage = nil
        pager.reset()
        onRetry = nil
        headerLabel.stringValue = ""
        statusLabel.stringValue = ""
    }

    private func resetRows() {
        for row in replyRows {
            row.releaseOffscreenResources()
            row.removeFromSuperview()
        }
        replyRows.removeAll(keepingCapacity: true)
    }

    @objc private func expand() { onExpand?() }
    @objc private func collapse() { onCollapse?() }
    @objc private func retry() { onRetry?() }
}
