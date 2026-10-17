import AppKit
import BiliApplication
import BiliModels
import Testing

@testable import BiliVideoDetailFeature

/// 评论列表与分页的失败行只在 `CommentReadError.isRetryable` 时给重试；不可重试的失败在同一行显示说明，
/// 无法发出的请求用与内容页相同的中性说明。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativePlaybackCommentsFailureTests {
    @Test(arguments: [CommentReadError.invalidRequest, .authenticationRequired, .transportFailure])
    @MainActor
    func rootFailureOffersRetryOnlyWhenRetryCanHelp(error: CommentReadError) {
        let title =
            switch error {
            case .invalidRequest: VideoDetailFeatureStrings.localized("当前无法完成这次请求。")
            case .authenticationRequired: VideoDetailFeatureStrings.localized("需要登录")
            default: VideoDetailFeatureStrings.localized("评论加载失败")
            }
        let item = NativePlaybackCommentsStateItem()
        item.configure(kind: .failed(error), onRetry: {})

        #expect(visibleButtons(in: item.view).isEmpty != error.isRetryable)
        #expect(visibleLabelTexts(in: item.view) == [title])
        #expect(item.view.accessibilityLabel() == title)
    }

    @Test(arguments: [CommentReadError.invalidRequest, .transportFailure])
    @MainActor
    func paginationFailureOffersRetryOnlyWhenRetryCanHelp(error: CommentReadError) {
        let text =
            error.isRetryable
            ? VideoDetailFeatureStrings.localized("后续评论加载失败")
            : VideoDetailFeatureStrings.localized("当前无法完成这次请求。")
        let comments = NativePlaybackCommentsPresentation(
            subject: .video(aid: 700_001),
            sort: .hot,
            rootState: .loaded,
            totalCount: 2,
            threads: [],
            paginationError: error
        )
        let item = NativePlaybackCommentsFooterItem()
        item.configure(footer: comments.footer, onRetry: {}, onLoadMore: {})

        #expect(comments.footer == .failed(error))
        #expect(visibleButtons(in: item.view).isEmpty != error.isRetryable)
        #expect(visibleLabelTexts(in: item.view) == [text])
    }

    @MainActor
    private func visibleButtons(in view: NSView) -> [NSButton] {
        descendants(of: view).compactMap { $0 as? NSButton }.filter { !$0.isHidden }
    }

    @MainActor
    private func visibleLabelTexts(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            .map(\.stringValue)
    }
}
