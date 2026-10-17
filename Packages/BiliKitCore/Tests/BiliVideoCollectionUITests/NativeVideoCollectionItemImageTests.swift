import AppKit
import Foundation
import QuartzCore
import Testing

@testable import BiliVideoCollectionUI

/// 卡片取图：缓存命中在配置当帧上图且不淡入；未命中时异步结果按是否刚从网络到达决定淡入。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeVideoCollectionItemImageTests {
    private static let coverURL = URL(string: "https://i0.hdslb.com/bfs/archive/fixture.jpg")!

    @Test
    func cachedCoverAppearsSynchronouslyWithoutFading() throws {
        let image = try #require(Self.makeImage())
        let item = NativeVideoCollectionItem()
        item.configure(
            presentation: Self.presentation,
            imagePipeline: StubCardImageLoader(cached: [Self.coverURL: image]),
            hoverChanged: { _, _ in },
            activation: { _ in }
        )

        let layer = try #require(Self.layer(showing: image, in: item.view))
        #expect(layer.animationKeys()?.isEmpty ?? true)
    }

    @Test(arguments: [true, false])
    func loadedCoverFadesOnlyWhenItArrivedFromTheNetwork(fadesIn: Bool) async throws {
        let image = try #require(Self.makeImage())
        let item = NativeVideoCollectionItem()
        item.configure(
            presentation: Self.presentation,
            imagePipeline: StubCardImageLoader(
                loaded: [Self.coverURL: NativeVideoCardImage(image: image, fadesIn: fadesIn)]
            ),
            hoverChanged: { _, _ in },
            activation: { _ in }
        )
        #expect(Self.layer(showing: image, in: item.view) == nil)

        let layer = try #require(await Self.waitForLayer(showing: image, in: item.view))
        let expectsFade = fadesIn && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect((layer.animationKeys()?.isEmpty == false) == expectsFade)
    }

    private static let presentation = NativeVideoCardPresentation(
        id: "BV1Fixture",
        title: "标题",
        coverURL: coverURL,
        avatarURL: nil,
        showsAvatar: false,
        footerLeadingText: "作者",
        accessibilityLabel: "标题，作者"
    )

    /// 卡片 layer 树里以这张图为内容的 layer；按内容身份查找，不依赖层级位置。
    private static func layer(showing image: CGImage, in view: NSView) -> CALayer? {
        func search(_ layer: CALayer) -> CALayer? {
            if let contents = layer.contents, (contents as AnyObject) === image { return layer }
            return layer.sublayers?.lazy.compactMap(search).first
        }
        let roots = ([view] + descendants(of: view)).compactMap(\.layer)
        return roots.lazy.compactMap(search).first
    }

    /// 让出主线程直到取图 Task 把结果写回；时长只作超时。
    private static func waitForLayer(showing image: CGImage, in view: NSView) async -> CALayer? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let layer = layer(showing: image, in: view) { return layer }
            await Task.yield()
        }
        return nil
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private static func makeImage() -> CGImage? {
        CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
