import AppKit
import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 楼中楼翻页列表里回复别人的回复带「查看对话」，点按交出这条回复；看对话时顶部换成「返回全部回复」、底部「加载更多」，
/// 回复行不再提供入口。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlaybackSidebarReplyDialogTests: PlaybackSidebarFixtures {
    @Test
    func pageListOffersViewConversationAndDialogModeOffersBackAndLoadMore() throws {
        let base = comment(id: 32, message: "回复别人的回复")
        let reply = BiliModels.Comment(
            id: base.id,
            rootID: CommentID(rawValue: 3),
            parentID: CommentID(rawValue: 31),
            dialogID: CommentID(rawValue: 31),
            payload: base.payload
        )
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        state.replies = [reply]
        state.totalCount = 2
        var shownDialogs: [BiliModels.Comment] = []
        var closedCount = 0
        let item = NativePlaybackCommentThreadItem()

        func configure(_ state: PlaybackCommentReplyState) {
            let row = NativePlaybackCommentThreadPresentation(
                subject: .video(aid: 700_001),
                thread: commentThread(id: 3, message: "根评论", replyCount: 2),
                replyState: state
            )
            item.view.frame = NSRect(
                x: 0,
                y: 0,
                width: 408,
                height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
            )
            item.configure(
                presentation: row,
                textRenderer: makeCommentTextRenderer(),
                avatarLoader: makeCommentAvatarLoader(),
                pictureLoader: makeCommentPictureLoader(),
                onTextLayoutChange: {},
                onExpand: {},
                onCollapse: {},
                onShowPage: { _ in },
                onRetry: {},
                onShowDialog: { shownDialogs.append($0) },
                onLoadMoreDialog: {},
                onCloseDialog: { closedCount += 1 },
                onOpenLink: { _ in },
                onOpenPictures: { _ in },
                onOpenAuthorSpace: nil
            )
            item.view.layoutSubtreeIfNeeded()
        }

        func visibleButton(_ title: String) -> NSButton? {
            descendants(of: item.view).compactMap { $0 as? NSButton }
                .first { !$0.isHidden && $0.title == title }
        }

        state.isLoading = true
        configure(state)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("查看对话")) == nil)

        state.isLoading = false
        configure(state)
        try #require(visibleButton(VideoDetailFeatureStrings.localized("查看对话"))).performClick(nil)
        #expect(shownDialogs == [reply])
        #expect(visibleButton(VideoDetailFeatureStrings.localized("返回全部回复")) == nil)

        var dialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        dialog.replies = [reply]
        dialog.hasLoadedFirstPage = true
        dialog.nextFloor = 3
        state.dialog = dialog
        configure(state)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("查看对话")) == nil)
        #expect(visibleButton(VideoDetailFeatureStrings.localized("加载更多")) != nil)
        try #require(visibleButton(VideoDetailFeatureStrings.localized("返回全部回复"))).performClick(nil)
        #expect(closedCount == 1)

        // 对话到底却没有可显示的回复：给一句说明，不留空白面板。
        var emptyDialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        emptyDialog.hasLoadedFirstPage = true
        state.dialog = emptyDialog
        configure(state)
        let message = VideoDetailFeatureStrings.localized("这串对话暂时没有可显示的回复")
        #expect(
            descendants(of: item.view).compactMap { $0 as? NSTextField }
                .contains { !$0.isHidden && $0.stringValue == message }
        )
        #expect(visibleButton(VideoDetailFeatureStrings.localized("加载更多")) == nil)
    }

    /// 进出对话、对话加载状态变化都改变这一行的 revision，侧栏据此重载这一行。
    @Test
    func dialogStateChangesTheThreadRevision() {
        let thread = commentThread(id: 3, message: "根评论", replyCount: 2)
        var state = PlaybackCommentReplyState()
        state.isExpanded = true
        func revision(_ state: PlaybackCommentReplyState) -> Int {
            NativePlaybackCommentThreadPresentation(
                subject: .video(aid: 700_001),
                thread: thread,
                replyState: state
            ).revision
        }
        let pageList = revision(state)

        var dialog = PlaybackCommentDialogState(dialogID: CommentID(rawValue: 31))
        dialog.isLoading = true
        state.dialog = dialog
        let loadingDialog = revision(state)
        dialog.isLoading = false
        dialog.hasLoadedFirstPage = true
        state.dialog = dialog
        let loadedDialog = revision(state)

        #expect(Set([pageList, loadingDialog, loadedDialog]).count == 3)
    }
}
