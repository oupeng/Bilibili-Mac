import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

@Suite
struct DanmakuTextureRasterizerTests {
    @Test
    func unionOuterRingDoesNotEnterFillAndMapsHalfPointAtOneAndTwoX() {
        let alpha: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let oneX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 0.5
        )
        let twoX = DanmakuTextureRasterizer.outerRing(
            alpha: alpha,
            width: 5,
            height: 5,
            radiusPixels: 1
        )

        #expect(oneX[2 * 5 + 2] == 0)
        #expect(twoX[2 * 5 + 2] == 0)
        #expect(oneX[2 * 5 + 1] == 128)
        #expect(twoX[2 * 5 + 1] == 255)
        #expect(oneX[1 * 5 + 1] == 128)
        #expect(twoX[1 * 5 + 1] == 255)

        let adjacent: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 255, 255, 255, 0,
            0, 0, 0, 0, 0
        ]
        let union = DanmakuTextureRasterizer.outerRing(
            alpha: adjacent,
            width: 5,
            height: 3,
            radiusPixels: 1
        )
        #expect(union[1 * 5 + 1] == 0)
        #expect(union[1 * 5 + 2] == 0)
        #expect(union[1 * 5 + 3] == 0)
    }

    @Test
    func onePointTentShadowIsZeroOffsetAndSymmetricAtOneAndTwoX() {
        let source: [UInt8] = [
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 255, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 0, 0
        ]
        let oneX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 1
        )
        let twoX = DanmakuTextureRasterizer.tentBlur(
            alpha: source,
            width: 5,
            height: 5,
            radius: 2
        )

        #expect(oneX[2 * 5 + 1] == oneX[2 * 5 + 3])
        #expect(oneX[1 * 5 + 2] == oneX[3 * 5 + 2])
        #expect(twoX[2 * 5] == twoX[2 * 5 + 4])
        #expect(twoX[2] == twoX[4 * 5 + 2])
        #expect(twoX[2 * 5 + 2] > twoX[2 * 5 + 1])
        #expect(twoX[2 * 5 + 1] > twoX[2 * 5])
    }

    @Test
    func cacheKeyChangesWithEveryVisualInput() throws {
        let baseEvent = fixtureEvent(
            id: "key",
            mode: .top,
            colorRGB: 0xFFFFFF,
            fontSize: 25
        )
        func key(
            _ event: DanmakuEvent,
            backingScale: Double = 2
        ) throws -> DanmakuTextureCacheKey {
            try #require(
                DanmakuTextureRasterizer.key(
                    event: event,
                    backingScale: backingScale
                )
            )
        }
        let base = try key(baseEvent)
        let variants = [
            try key(
                DanmakuEvent(
                    id: "key-2",
                    timeSeconds: 1,
                    mode: .top,
                    text: "different",
                    fontSize: 25,
                    colorRGB: 0xFFFFFF,
                    colorStyle: .solid,
                    weight: 1
                )
            ),
            try key(baseEvent, backingScale: 1),
            try key(
                fixtureEvent(id: "key-color", mode: .top, colorRGB: 0x204060, fontSize: 25)
            ),
            try key(
                fixtureEvent(id: "key-size", mode: .top, colorRGB: 0xFFFFFF, fontSize: 36)
            )
        ]

        for variant in variants {
            #expect(variant != base)
        }
    }

    /// 车道布局只测量、不栅格化，得到的尺寸必须与在屏纹理逐像素一致，否则滚动速度与追尾判断会漂移。
    @Test(arguments: [1.0, 2.0, 3.0])
    func measurementMatchesTheRasterizedTexture(backingScale: Double) throws {
        let events = [
            fixtureEvent(id: "mixed", mode: .scrolling, fontSize: 25),
            fixtureEvent(id: "small", mode: .top, colorRGB: 0x204060, fontSize: 18),
            DanmakuEvent(
                id: "vip",
                timeSeconds: 1,
                mode: .bottom,
                text: "大会员 VIP",
                fontSize: 36,
                colorRGB: 0x00FF00,
                colorStyle: .vipGradient,
                weight: 1
            )
        ]
        var cache = DanmakuTextMeasurementCache()
        for event in events {
            let key = try #require(
                DanmakuTextureRasterizer.key(event: event, backingScale: backingScale)
            )
            let texture = try #require(DanmakuTextureRasterizer.rasterize(key: key))
            #expect(cache.metrics(for: event, backingScale: backingScale) == texture.metrics)
        }
    }

    /// 大会员彩色弹幕：缓存键与普通弹幕区分，填充固定为白色、不随事件颜色变化。
    @Test
    func vipGradientKeyIsDistinctAndAlwaysWhite() throws {
        func event(_ style: DanmakuColorStyle, colorRGB: UInt32) -> DanmakuEvent {
            DanmakuEvent(
                id: "vip",
                timeSeconds: 1,
                mode: .scrolling,
                text: "彩色弹幕",
                fontSize: 25,
                colorRGB: colorRGB,
                colorStyle: style,
                weight: 1
            )
        }
        let solid = try #require(
            DanmakuTextureRasterizer.key(event: event(.solid, colorRGB: 0xFFFFFF), backingScale: 2)
        )
        let vip = try #require(
            DanmakuTextureRasterizer.key(
                event: event(.vipGradient, colorRGB: 0xFFFFFF),
                backingScale: 2
            )
        )
        let tintedVIP = try #require(
            DanmakuTextureRasterizer.key(
                event: event(.vipGradient, colorRGB: 0x204060),
                backingScale: 2
            )
        )

        #expect(vip != solid)
        #expect(tintedVIP == vip)
        #expect(vip.colorRGB == DanmakuTextureRasterizer.vipGradientFillRGB)
    }

    /// 渐变两端与中点落在采样色标上，超出文字范围时取端点。
    @Test
    func vipGradientColorFollowsTheSampledStops() {
        let stops = DanmakuTextureRasterizer.vipGradientStops
        func same(
            _ lhs: (red: UInt8, green: UInt8, blue: UInt8),
            _ rhs: (red: UInt8, green: UInt8, blue: UInt8)
        ) -> Bool {
            lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue
        }

        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 0), stops[0]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: -1), stops[0]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 0.5), stops[2]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 1), stops[stops.count - 1]))
        #expect(same(DanmakuTextureRasterizer.vipGradientColor(at: 2), stops[stops.count - 1]))
    }

    /// 彩色弹幕的描边左段偏粉、右段偏蓝；同样文字的普通白色弹幕没有彩色像素。
    @Test
    func vipGradientOutlineRunsFromPinkOnTheLeftToBlueOnTheRight() throws {
        func texture(_ style: DanmakuColorStyle) throws -> DanmakuTexturePayload {
            let key = DanmakuTextureCacheKey(
                text: "一二三四五六七八",
                fontSize: 25,
                colorRGB: 0xFFFFFF,
                colorStyle: style,
                backingScale: 2
            )
            return try #require(DanmakuTextureRasterizer.rasterize(key: key))
        }
        /// 某一段列里所有像素的红减蓝之和；白字与深色阴影的红蓝相等，只有渐变描边贡献差值。
        func redMinusBlue(_ payload: DanmakuTexturePayload, columns: Range<Int>) -> Int {
            let bytes = [UInt8](payload.pixels)
            var total = 0
            for row in 0..<payload.heightPixels {
                for column in columns {
                    let offset = row * payload.bytesPerRow + column * 4
                    total += Int(bytes[offset]) - Int(bytes[offset + 2])
                }
            }
            return total
        }
        let vip = try texture(.vipGradient)
        let solid = try texture(.solid)
        let quarter = vip.widthPixels / 4

        #expect(redMinusBlue(vip, columns: 0..<quarter) > 0)
        #expect(redMinusBlue(vip, columns: (vip.widthPixels - quarter)..<vip.widthPixels) < 0)
        #expect(redMinusBlue(solid, columns: 0..<solid.widthPixels) == 0)
    }

    @Test
    @MainActor
    func byteBoundedCacheUsesLRUAndRejectsOversizedItems() throws {
        let limits = CostBoundedLRUCacheLimits(
            maximumItemCost: 64,
            maximumTotalCost: 96
        )
        let cache = CostBoundedLRUCache<DanmakuTextureCacheKey, DanmakuTexturePayload>(
            limits: limits
        )
        let first = textureKey(text: "first")
        let second = textureKey(text: "second")
        let third = textureKey(text: "third")
        let payload = fixtureTexturePayload(byteCost: 48)

        let insertedFirst = cache.insert(payload, cost: payload.byteCost, for: first)
        let insertedSecond = cache.insert(payload, cost: payload.byteCost, for: second)
        let firstHit = cache.value(for: first)
        let insertedThird = cache.insert(payload, cost: payload.byteCost, for: third)
        let evictedSecond = cache.value(for: second)
        let retainedFirst = cache.value(for: first)
        let retainedThird = cache.value(for: third)
        #expect(insertedFirst)
        #expect(insertedSecond)
        #expect(firstHit == payload)
        #expect(insertedThird)
        #expect(evictedSecond == nil)
        #expect(retainedFirst == payload)
        #expect(retainedThird == payload)
        #expect(cache.totalCost == 96)
        let oversized = fixtureTexturePayload(byteCost: 68)
        let insertedOversized = cache.insert(oversized, cost: oversized.byteCost, for: second)
        #expect(!insertedOversized)
        #expect(cache.totalCost == 96)
        cache.removeAll()
        #expect(cache.totalCost == 0)
    }

    private func textureKey(text: String) -> DanmakuTextureCacheKey {
        DanmakuTextureCacheKey(
            text: text,
            fontSize: 25,
            colorRGB: 0xFFFFFF,
            colorStyle: .solid,
            backingScale: 2
        )
    }
}

func fixtureTexturePayload(byteCost: Int) -> DanmakuTexturePayload {
    DanmakuTexturePayload(
        pixels: Data(repeating: 1, count: byteCost),
        widthPixels: byteCost / 4,
        heightPixels: 1,
        bytesPerRow: byteCost,
        backingScale: 1
    )
}
