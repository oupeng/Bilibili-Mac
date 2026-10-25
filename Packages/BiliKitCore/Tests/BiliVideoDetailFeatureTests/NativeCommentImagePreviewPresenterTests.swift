import AppKit
import Testing

@testable import BiliVideoDetailFeature

/// 评论图片预览面板的打开与关闭：面板是格子所在窗口的子窗口并铺满它，同时最多一个；换到别的视频、退出播放与
/// 关窗时关闭且不动焦点，用户关闭（⌘W、Esc）时把焦点交还格子。
///
/// 不断言 key window：它取决于窗口服务器与 App 是否处于前台。
@MainActor
struct NativeCommentImagePreviewPresenterTests {
    private final class FocusRecorder {
        var restoreCount = 0
    }

    private let parent = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.borderless],
        backing: .buffered,
        defer: true
    )
    private let focus = FocusRecorder()
    private let presenter = NativeCommentImagePreviewPresenter(
        imagePipeline: StubVideoDetailImageLoader(),
        resolveURL: { _, _ in nil },
        imageSaver: NativeCommentImageSaver()
    )

    @Test
    func previewCoversItsSourceWindowAndReplacesTheEarlierOne() throws {
        presenter.present(try request(bvid: "BV1"))
        let first = try #require(previewPanels.first)
        #expect(previewPanels.count == 1)
        #expect(first.parent === parent)
        #expect(first.frame == parent.frame)

        presenter.present(try request(bvid: "BV1"))
        #expect(previewPanels.count == 1)
        #expect(previewPanels.first !== first)
        #expect(focus.restoreCount == 0)

        presenter.close()
        #expect(previewPanels.isEmpty)
        #expect(focus.restoreCount == 0)
    }

    @Test
    func changingOrLeavingPlaybackClosesWithoutMovingFocus() throws {
        presenter.present(try request(bvid: "BV1"))
        presenter.playbackDidChange(to: "BV1")
        #expect(previewPanels.count == 1)

        presenter.playbackDidChange(to: "BV2")
        #expect(previewPanels.isEmpty)

        presenter.present(try request(bvid: "BV2"))
        presenter.playbackDidChange(to: nil)
        #expect(previewPanels.isEmpty)
        #expect(focus.restoreCount == 0)
    }

    @Test
    func userDismissalRestoresFocusToTheTile() throws {
        presenter.present(try request(bvid: "BV1"))
        try #require(previewPanels.first).performClose(nil)
        #expect(previewPanels.isEmpty)
        #expect(focus.restoreCount == 1)

        presenter.present(try request(bvid: "BV1"))
        try #require(previewPanels.first).cancelOperation(nil)
        #expect(previewPanels.isEmpty)
        #expect(focus.restoreCount == 2)

        presenter.close()
        #expect(focus.restoreCount == 2)
    }

    private var previewPanels: [NativeCommentImagePreviewPanel] {
        (parent.childWindows ?? []).compactMap { $0 as? NativeCommentImagePreviewPanel }
    }

    private func request(bvid: String) throws -> NativeCommentImagePreviewRequest {
        let parent = parent
        let focus = focus
        return try #require(
            NativeCommentImagePreviewRequest(
                bvid: bvid,
                gallery: NativePlaybackCommentPictureGallery(
                    references: [fixtureAssetReference()],
                    selectedIndex: 0,
                    sourceWindow: { parent },
                    restoreFocus: { focus.restoreCount += 1 }
                )
            )
        )
    }
}
