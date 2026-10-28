import BiliModels
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 计数胶囊的契约：条数是媒体时间的纯函数；预留宽度按最终条数的位数；胶囊挂在正文右缘之外，条数、宽度与显隐
/// 都是从弹幕时间点开始的关键帧动画，在屏期间不会变化的胶囊不挂；减弱动态效果时不跳。
@MainActor
@Suite
struct DanmakuCountBadgeTests {
    @Test
    func countFollowsMediaTimeAndWidthReservesTheFinalDigits() throws {
        let badge = try #require(DanmakuCountBadge(laterArrivalTimes: [11, 12, 12], fontSize: 25))
        #expect(badge.finalCount == 4)
        #expect([10, 11, 11.5, 12, 30].map(badge.count(at:)) == [1, 2, 2, 4, 4])
        #expect(DanmakuCountBadge(laterArrivalTimes: [], fontSize: 25) == nil)

        let nine = try #require(
            DanmakuCountBadge(laterArrivalTimes: Array(repeating: 1, count: 8), fontSize: 25)
        )
        let ten = try #require(
            DanmakuCountBadge(laterArrivalTimes: Array(repeating: 1, count: 9), fontSize: 25)
        )
        let geometry = DanmakuCountBadgeGeometry.geometry(forFontSize: 25)
        #expect(ten.reservedWidth - nine.reservedWidth == Double(geometry.digitWidth))
    }

    /// 同一时刻到达的几条合成一步；离场时或之后才到的不显示。
    @Test
    func stepsMergeSimultaneousArrivalsAndStopAtExpiry() throws {
        let badge = try #require(
            DanmakuCountBadge(laterArrivalTimes: [11, 12, 12, 14, 15], fontSize: 25)
        )
        let steps = DanmakuCountBadgeLayers.countSteps(
            badge: badge,
            admittedAtSeconds: 10,
            duration: 4
        )
        #expect(steps.map(\.count) == [2, 4])
        #expect(steps.map(\.fraction) == [0.25, 0.5])
    }

    @Test(arguments: [false, true])
    func badgeHangsRightOfTheTextAndAnimatesFromTheDanmakuTime(reducesMotion: Bool) throws {
        let badge = try #require(
            DanmakuCountBadge(laterArrivalTimes: [11, 12, 13], fontSize: 25)
        )
        let layer = CALayer()
        let layers = DanmakuCountBadgeLayers()
        layers.replaceBadge(
            on: layer,
            badge: badge,
            textWidth: 120,
            height: 36,
            admittedAtSeconds: 10,
            beginTime: 10,
            duration: 8,
            backingScale: 2,
            reducesMotion: reducesMotion
        )

        let pill = try #require(
            layer.sublayers?.first { $0.name == DanmakuCountBadgeLayers.layerName }
        )
        let geometry = DanmakuCountBadgeGeometry.geometry(forFontSize: 25)
        #expect(pill.frame.minX == 120 + geometry.spacing)
        #expect(pill.opacity == 0)
        let keys = Set(pill.animationKeys() ?? [])
        #expect(keys.contains("opacity"))
        #expect(keys.contains("bounds.size.width"))
        #expect(keys.contains("transform.scale") == !reducesMotion)
        let opacity = try #require(pill.animation(forKey: "opacity") as? CAKeyframeAnimation)
        #expect(opacity.beginTime == 10)
        #expect(opacity.keyTimes == [0, 0.125, 1])
        // “×”加一位数字。
        #expect(pill.sublayers?.count == 2)

        layers.replaceBadge(
            on: layer,
            badge: nil,
            textWidth: 120,
            height: 36,
            admittedAtSeconds: 10,
            beginTime: 10,
            duration: 8,
            backingScale: 2,
            reducesMotion: reducesMotion
        )
        #expect(layer.sublayers?.isEmpty ?? true)
    }

    @Test
    func badgeThatNeverChangesOnScreenIsNotAttached() throws {
        let badge = try #require(DanmakuCountBadge(laterArrivalTimes: [20], fontSize: 25))
        let layer = CALayer()
        DanmakuCountBadgeLayers().replaceBadge(
            on: layer,
            badge: badge,
            textWidth: 120,
            height: 36,
            admittedAtSeconds: 10,
            beginTime: 10,
            duration: 8,
            backingScale: 2,
            reducesMotion: false
        )
        #expect(layer.sublayers?.isEmpty ?? true)
    }
}
