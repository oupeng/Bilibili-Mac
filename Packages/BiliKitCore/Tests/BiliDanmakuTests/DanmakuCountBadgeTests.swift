import BiliModels
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 计数胶囊的契约：条数是媒体时间的纯函数；预留宽度按最终条数的位数；胶囊挂在正文右缘之外，条数、宽度与显隐
/// 都是从弹幕时间点开始的关键帧动画，在屏期间不会变化的胶囊不挂；条数变化不带动画。
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

    @Test
    func badgeHangsRightOfTheTextAndAnimatesFromTheDanmakuTime() throws {
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
            backingScale: 2
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
        #expect(!keys.contains("transform.scale"))
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
            backingScale: 2
        )
        #expect(layer.sublayers?.isEmpty ?? true)
    }

    /// 位数增加之前，多出来的那一位不可见，不靠胶囊宽度裁剪（它的格子与胶囊右内边距重叠）。
    @Test
    func laterDigitStaysHiddenUntilTheCountGainsADigit() throws {
        let arrivals = (1...9).map { 10 + Double($0) * 0.5 }
        let badge = try #require(DanmakuCountBadge(laterArrivalTimes: arrivals, fontSize: 25))
        let layer = CALayer()
        DanmakuCountBadgeLayers().replaceBadge(
            on: layer,
            badge: badge,
            textWidth: 120,
            height: 36,
            admittedAtSeconds: 10,
            beginTime: 10,
            duration: 8,
            backingScale: 2
        )

        let pill = try #require(
            layer.sublayers?.first { $0.name == DanmakuCountBadgeLayers.layerName }
        )
        let digitLayers = try #require(pill.sublayers?.dropFirst())
        #expect(digitLayers.count == 2)
        let tens = try #require(digitLayers.first)
        let units = try #require(digitLayers.last)
        #expect(tens.opacity == 1)
        #expect(units.opacity == 0)
        let reveal = try #require(units.animation(forKey: "opacity") as? CAKeyframeAnimation)
        // 第 9 个到达（14.5 秒）时条数变为 10。
        #expect(reveal.keyTimes == [0, 0.5625, 1])
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
            backingScale: 2
        )
        #expect(layer.sublayers?.isEmpty ?? true)
    }
}
