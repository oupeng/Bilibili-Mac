import BiliModels
import CoreGraphics
import Foundation
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 关联视频卡片的契约：只在显示区间内、按卡片在画面上的位置给出可点的卡片，评分与投票不算；封面先查缓存，
/// 未命中时异步加载后放进卡片的封面子层，换 backing scale 重画时沿用已到的封面。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuLinkCardTests {
    @Test
    func onlyLinkCardsInsideTheirTimeWindowAreVisibleAtTheirOnScreenFrame() throws {
        let renderer = CoreAnimationDanmakuRenderer(beginTimeAtMediaZero: 1e-100)
        // 宿主 layer 与 AppKit 视图一样 y 轴向上；renderer 的根层 y 轴向下。
        let host = CALayer()
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 450)
        host.addSublayer(renderer.rootLayer)
        renderer.updateSurfaceSize(width: 800, height: 450, backingScale: 2)
        renderer.setCommandCards([Self.linkCard(coverURL: nil), Self.gradeCard])

        #expect(renderer.visibleLinkCards(displayTime: 11.9, in: host).isEmpty)
        #expect(renderer.visibleLinkCards(displayTime: 17, in: host).isEmpty)
        let visible = try #require(renderer.visibleLinkCards(displayTime: 12, in: host).first)
        #expect(renderer.visibleLinkCards(displayTime: 16.9, in: host).count == 1)
        #expect(visible.card.bvid == "BV18NHg6KEkb")
        #expect(visible.frame.width == DanmakuCommandCardArtwork.cardWidth)
        // 中心在离顶边 25% 处，换到 y 轴向上的宿主坐标是离底边 75%。
        #expect(abs(visible.frame.midY - 450 * 0.75) < 0.001)
        #expect(abs(visible.frame.midX - 400) < 0.001)

        renderer.stop()
        #expect(renderer.visibleLinkCards(displayTime: 12, in: host).isEmpty)
    }

    @Test
    func cachedCoverShowsAtOnceAndSurvivesARedraw() throws {
        let image = try Self.image()
        let layers = DanmakuCommandCardLayers { $0 }
        layers.coverImages = StubCoverImages(cached: image, loaded: nil)
        layers.updateSurface(size: CGSize(width: 800, height: 450), backingScale: 2)
        layers.setCards([Self.linkCard(coverURL: Self.coverURL)], reducesMotion: false)
        #expect(try Self.coverLayer(in: layers).contents != nil)

        layers.updateSurface(size: CGSize(width: 800, height: 450), backingScale: 1)
        #expect(try Self.coverLayer(in: layers).contents != nil)
    }

    @Test
    func uncachedCoverArrivesIntoTheCoverLayer() async throws {
        let layers = DanmakuCommandCardLayers { $0 }
        layers.coverImages = StubCoverImages(cached: nil, loaded: try Self.image())
        layers.updateSurface(size: CGSize(width: 800, height: 450), backingScale: 2)
        layers.setCards([Self.linkCard(coverURL: Self.coverURL)], reducesMotion: false)
        let cover = try Self.coverLayer(in: layers)
        #expect(cover.contents == nil)

        // 加载 Task 回到主线程后才换封面；完成以状态判断，超时由 Suite 的时限兜底。
        while cover.contents == nil {
            await Task.yield()
        }
        #expect(cover.frame.size == DanmakuCommandCardArtwork.coverSize)
    }

    private static let coverURL = URL(string: "https://i0.hdslb.com/bfs/archive/cover.jpg")!

    private static func linkCard(coverURL: URL?) -> DanmakuCommandCard {
        DanmakuCommandCard(
            id: "command:link",
            timeSeconds: 12,
            durationSeconds: 5,
            position: DanmakuCardPosition(x: 0.5, y: 0.25),
            content: .link(
                DanmakuLinkCard(bvid: "BV18NHg6KEkb", title: "关联视频标题", coverURL: coverURL)
            )
        )
    }

    private static let gradeCard = DanmakuCommandCard(
        id: "command:grade",
        timeSeconds: 12,
        durationSeconds: 5,
        position: DanmakuCardPosition(x: 0.5, y: 0.65),
        content: .grade(
            DanmakuGradeCard(title: "评分", averageScore: 9.9, participantCount: 1, myScore: nil)
        )
    )

    private static func coverLayer(in layers: DanmakuCommandCardLayers) throws -> CALayer {
        let card = try #require(layers.containerLayer.sublayers?.first)
        return try #require(card.sublayers?.first)
    }

    private static func image() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try #require(context.makeImage())
    }
}

/// 固定返回值的封面来源：缓存命中时给 `cached`，异步加载给 `loaded`。
private final class StubCoverImages: DanmakuCoverImageLoading {
    let cached: CGImage?
    let loaded: CGImage?

    init(cached: CGImage?, loaded: CGImage?) {
        self.cached = cached
        self.loaded = loaded
    }

    func cachedDanmakuCover(for url: URL) -> CGImage? {
        cached
    }

    func danmakuCover(for url: URL) async -> CGImage? {
        loaded
    }
}
