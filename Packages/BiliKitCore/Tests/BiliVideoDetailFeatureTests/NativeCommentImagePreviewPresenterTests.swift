import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import BiliVideoDetailFeature

/// 评论图片预览面板的打开与关闭：面板是格子所在窗口的子窗口并铺满它，同时最多一个；换到别的视频、退出播放与
/// 关窗时关闭且不动焦点，用户关闭（⌘W、Esc）时把焦点交还格子；面板尺寸只跟随父窗口，内容（缩小图占位、
/// 远大于父窗口的原图、动图）再大也不推动面板。
///
/// 不断言 key window：它取决于窗口服务器与 App 是否处于前台。只驱动布局与绘制，不进事件循环。
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

    @Test
    func contentLargerThanTheParentDoesNotResizeThePanel() async throws {
        let original = try #require(Self.makeImage(width: 4000, height: 6000))
        let thumbnail = try #require(Self.makeImage(width: 400, height: 600))
        let animation = NativeAnimatedImage(data: try #require(Self.makeGIF(width: 64, height: 96)))
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        let loaders = [
            // 原图已缓存（含动图），打开即显示原图。
            StubVideoDetailImageLoader(
                cachedImages: [.commentPicturePreview: original],
                cachedAnimations: [.commentPicturePreview: animation]
            ),
            // 只有缩小图占位，原图加载后原位替换。
            StubVideoDetailImageLoader(
                cachedImages: [.commentPicture: thumbnail],
                loadedImage: VideoDetailImage(image: original, animation: animation, fadesIn: true)
            )
        ]
        for loader in loaders {
            let presenter = NativeCommentImagePreviewPresenter(
                imagePipeline: loader,
                resolveURL: { _, _ in URL(string: "https://example.invalid/picture.png") },
                imageSaver: NativeCommentImageSaver()
            )
            presenter.present(try request(bvid: "BV1", in: parent, count: 3))
            let panel = try #require(
                parent.childWindows?.compactMap { $0 as? NativeCommentImagePreviewPanel }.first
            )
            for _ in 0..<5 {
                panel.layoutIfNeeded()
                panel.displayIfNeeded()
                await Task.yield()
                #expect(panel.frame == parent.frame)
            }
            presenter.close()
        }
    }

    private var previewPanels: [NativeCommentImagePreviewPanel] {
        (parent.childWindows ?? []).compactMap { $0 as? NativeCommentImagePreviewPanel }
    }

    private func request(
        bvid: String,
        in window: NSWindow? = nil,
        count: Int = 1
    ) throws -> NativeCommentImagePreviewRequest {
        let parent = window ?? parent
        let focus = focus
        return try #require(
            NativeCommentImagePreviewRequest(
                bvid: bvid,
                gallery: NativePlaybackCommentPictureGallery(
                    references: (0..<count).map { _ in fixtureAssetReference() },
                    selectedIndex: 0,
                    sourceWindow: { parent },
                    restoreFocus: { focus.restoreCount += 1 }
                )
            )
        )
    }

    private static func makeImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    /// 两帧的 GIF 编码数据。
    private static func makeGIF(width: Int, height: Int) -> Data? {
        let data = NSMutableData()
        guard
            let frame = makeImage(width: width, height: height),
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.gif.identifier as CFString,
                2,
                nil
            )
        else { return nil }
        let properties =
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        CGImageDestinationAddImage(destination, frame, properties)
        CGImageDestinationAddImage(destination, frame, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
