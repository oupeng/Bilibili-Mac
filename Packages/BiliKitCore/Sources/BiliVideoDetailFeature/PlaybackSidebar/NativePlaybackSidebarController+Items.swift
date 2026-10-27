import AppKit
import BiliApplication
import BiliModels
import BiliVideoCollectionUI

/// 单元格的创建与配置：按条目身份取出呈现，接上动作回调；同一视频内可见的 UP 主行原地更新。
extension NativePlaybackSidebarController {
    private func configureUploader(
        _ item: NativePlaybackSidebarUploaderItem,
        content: VideoUploaderHeaderContent
    ) {
        item.configure(
            content: content,
            imagePipeline: imagePipeline,
            onOpenSpace: actions.openUploaderSpace == nil
                ? nil : { [weak self] in self?.releasingFocus { $0.actions.openUploaderSpace?() } }
        )
    }

    /// 同一视频内可见的 UP 主行原地更新、不整项重载，返回已处理的项。
    ///
    /// 重载会换掉视图，名片到达时就没有旧画面可淡出（见 `NativePlaybackUploaderProfileReveal`）。
    func reconfigureVisibleUploader(
        in changedItemIDs: Set<NativePlaybackSidebarItemID>
    ) -> Set<NativePlaybackSidebarItemID> {
        guard let content = presentation.content else { return [] }
        let uploaderID = NativePlaybackSidebarItemID.uploader(bvid: content.bvid)
        guard changedItemIDs.contains(uploaderID),
            let indexPath = dataSource?.indexPath(for: uploaderID),
            let item = collectionView.item(at: indexPath)
                as? NativePlaybackSidebarUploaderItem
        else { return [] }
        configureUploader(item, content: content.uploader)
        return [uploaderID]
    }

    func makeItem(
        collectionView: NSCollectionView,
        indexPath: IndexPath,
        itemID: NativePlaybackSidebarItemID
    ) -> NSCollectionViewItem? {
        guard let content = presentation.content else { return nil }
        switch itemID {
        case .uploader:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarUploaderItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarUploaderItem
            else { return nil }
            configureUploader(item, content: content.uploader)
            return item
        case .summary:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSummaryItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSummaryItem
            else { return nil }
            item.configure(
                summary: content.summary,
                links: content.summaryLinks,
                timestampLimitSeconds: content.timestampLimitSeconds,
                expanded: summaryExpanded,
                onToggle: { [weak self] in self?.toggleSummary() },
                onOpenLink: { [weak self] target in
                    self?.releasingFocus { $0.actions.openCommentLink(target) }
                }
            )
            return item
        case .selection:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackSidebarSelectionItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackSidebarSelectionItem
            else { return nil }
            item.configure(
                projection: content.selection,
                browsedSectionID: browsedSectionID,
                onSelectSection: { [weak self] in self?.browseSection($0) },
                onSelectEpisode: { [weak self] in self?.actions.selectEpisode($0) },
                onSelectPage: { [weak self] cid in
                    guard self?.presentation.content?.bvid == content.bvid else { return }
                    self?.actions.selectPage(content.bvid, cid)
                },
                onRetryPages: { [weak self] in self?.actions.retryPages() }
            )
            return item
        case .commentsHeader:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsHeaderItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsHeaderItem
            else { return nil }
            item.configure(
                presentation: content.comments,
                onSelectSort: { [weak self] in self?.actions.selectCommentSort($0) }
            )
            return item
        case .commentsState(_, let kind):
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsStateItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsStateItem
            else { return nil }
            item.configure(
                kind: kind,
                onRetry: { [weak self] in self?.actions.retryComments() }
            )
            return item
        case .commentThread(_, let rootID):
            guard
                let thread = commentThreadsByItemID[itemID],
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentThreadItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentThreadItem
            else { return nil }
            item.configure(
                presentation: thread,
                textRenderer: commentTextRenderer,
                avatarLoader: commentAvatarLoader,
                pictureLoader: commentPictureLoader,
                onTextLayoutChange: { [weak self] in
                    self?.commentTextLayoutDidChange(for: itemID)
                },
                onExpand: { [weak self] in self?.actions.expandReplies(rootID) },
                onCollapse: { [weak self] in
                    self?.prepareThreadAlignment(itemID, edge: .root)
                    self?.actions.collapseReplies(rootID)
                },
                onShowPage: { [weak self] page in
                    self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                    self?.actions.showReplyPage(rootID, page)
                },
                onRetry: { [weak self] in self?.actions.retryReplies(rootID) },
                onShowDialog: { [weak self] reply in
                    self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                    self?.actions.showDialog(rootID, reply)
                },
                onLoadMoreDialog: { [weak self] in self?.actions.loadMoreDialog(rootID) },
                onCloseDialog: { [weak self] in
                    self?.prepareThreadAlignment(itemID, edge: .repliesPanel)
                    self?.actions.closeDialog(rootID)
                },
                onOpenLink: { [weak self] target in
                    self?.releasingFocus { $0.actions.openCommentLink(target) }
                },
                onOpenPictures: { [weak self] in
                    self?.actions.openCommentPictures($0)
                },
                onOpenAuthorSpace: actions.openCommentAuthorSpace == nil
                    ? nil
                    : { [weak self] author in
                        self?.releasingFocus { $0.actions.openCommentAuthorSpace?(author) }
                    }
            )
            return item
        case .commentsFooter:
            guard
                let item = collectionView.makeItem(
                    withIdentifier: NativePlaybackCommentsFooterItem.reuseIdentifier,
                    for: indexPath
                ) as? NativePlaybackCommentsFooterItem
            else { return nil }
            item.configure(
                footer: content.comments.footer,
                onRetry: { [weak self] in self?.actions.retryComments() },
                onLoadMore: { [weak self] in self?.actions.loadNextComments() }
            )
            return item
        }
    }
}
