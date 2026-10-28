import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 互动弹幕在呈现端的契约：卡片只在弹幕开着、已有本视频时间线时交给 renderer，关闭、换 item、停止时撤下；
/// 卡片按媒体时间显隐、中心按位置比例落在窗口里并往里收；UP 主弹幕不参与重复合并，带标签与黑底后只加宽、不加高。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuCommandPresentationTests {
    private let identity = PlaybackItemIdentity(bvid: "BV1CommandCards", cid: 9)

    @Test
    func cardsFollowTheTimelineIdentityAndTheDanmakuSwitch() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(backend: backend)
        let cards = [Self.gradeCard]

        // 新视频的卡片先于它的第一个快照到达时先记下，快照到了才显示。
        controller.setCommandCards(cards, for: identity)
        #expect(backend.commandCardChanges.isEmpty)
        controller.apply(snapshot(identity: identity, position: 1, generation: 1))
        #expect(backend.commandCardChanges == [cards])

        controller.setEnabled(false)
        controller.setEnabled(true)
        // 换 item 时先撤下，等新 item 的快照确认 identity 再显示。
        let owner = UUID()
        controller.attachSurface(ownerID: owner, clock: ManualDisplayClock())
        controller.playerItemWillChange(ownerID: owner)
        controller.apply(snapshot(identity: identity, position: 2, generation: 1))
        controller.stopPresentation()
        #expect(backend.commandCardChanges == [cards, [], cards, [], cards, []])
    }

    @Test
    func cardsLayOutByFractionAndStayInsideTheWindow() {
        let size = CGSize(width: 200, height: 60)
        let surface = CGSize(width: 800, height: 450)
        let margin = DanmakuCommandCardLayers.edgeMargin

        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.5, y: 0.65),
                cardSize: size,
                in: surface
            ) == CGPoint(x: 400, y: 450 * 0.65)
        )
        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.97, y: 0.99),
                cardSize: size,
                in: surface
            ) == CGPoint(x: 800 - margin - 100, y: 450 - margin - 30)
        )
        #expect(
            DanmakuCommandCardLayers.center(
                for: DanmakuCardPosition(x: 0.9, y: 0.5),
                cardSize: size,
                in: CGSize(width: 150, height: 450)
            ).x == 75
        )
    }

    @Test(arguments: [false, true])
    func cardLayersFadeDuringTheirMediaTime(reducesMotion: Bool) throws {
        let layers = DanmakuCommandCardLayers(backingScale: 2) { $0 }
        layers.updateSurface(size: CGSize(width: 800, height: 450), backingScale: 2)
        layers.setCards([Self.gradeCard], reducesMotion: reducesMotion)

        let layer = try #require(layers.containerLayer.sublayers?.first)
        let animation = try #require(
            layer.animation(forKey: DanmakuCommandCardLayers.animationKey) as? CAKeyframeAnimation
        )
        #expect(layer.opacity == 0)
        #expect(animation.beginTime == 12)
        #expect(animation.duration == 5)
        #expect(animation.keyTimes == [0, 0.04, 0.96, 1])
        let scale = layer.animation(forKey: DanmakuCommandCardLayers.scaleAnimationKey)
        #expect((scale == nil) == reducesMotion)
        #expect(layer.bounds.width == DanmakuCommandCardArtwork.cardWidth)
        #expect(layer.contents != nil)

        layers.updateSurface(size: CGSize(width: 400, height: 300), backingScale: 2)
        #expect(layers.containerLayer.sublayers?.first === layer)
        #expect(layer.position.x == 200)

        layers.setCards([], reducesMotion: reducesMotion)
        #expect(layers.containerLayer.sublayers?.isEmpty ?? true)
    }

    @Test
    func uploaderDanmakuIsNeverMerged() {
        let events = [
            fixtureEvent(id: "fan", mode: .scrolling),
            fixtureEvent(id: "up", mode: .scrolling, isUploader: true),
            fixtureEvent(id: "fan-2", mode: .scrolling)
        ]

        let groups = DanmakuDuplicateMerger.merged(events)

        #expect(groups.map(\.event.id) == ["fan", "up"])
        #expect(groups.map(\.laterArrivalTimes.count) == [1, 0])
    }

    /// UP 主弹幕的标签与黑底画在同一张纹理里：比同文的普通弹幕宽、一样高，所以占同样多的车道；测量与纹理一致。
    @Test(arguments: [18.0, 25, 36])
    func uploaderTextureIsWiderButNotTaller(fontSize: Double) throws {
        func texture(isUploader: Bool) throws -> (DanmakuTexturePayload, DanmakuTextMetrics?) {
            let event = fixtureEvent(
                id: "up",
                mode: .scrolling,
                fontSize: fontSize,
                isUploader: isUploader
            )
            let key = try #require(DanmakuTextureRasterizer.key(event: event, backingScale: 2))
            var cache = DanmakuTextMeasurementCache()
            return (
                try #require(DanmakuTextureRasterizer.rasterize(key: key)),
                cache.metrics(for: event, backingScale: 2)
            )
        }
        let (plain, _) = try texture(isUploader: false)
        let (uploader, measured) = try texture(isUploader: true)
        #expect(uploader.widthPixels > plain.widthPixels)
        #expect(uploader.heightPixels == plain.heightPixels)
        #expect(measured == uploader.metrics)
    }

    private static let gradeCard = DanmakuCommandCard(
        id: "command:1",
        timeSeconds: 12,
        durationSeconds: 5,
        position: DanmakuCardPosition(x: 0.5, y: 0.65),
        content: .grade(
            DanmakuGradeCard(title: "评分", averageScore: 9.9, participantCount: 8029, myScore: nil)
        )
    )
}
