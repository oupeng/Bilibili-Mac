import Accelerate
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 纹理合成的像素契约：描边环只在字形外侧并按覆盖率减弱；单色铺色、大会员渐变与 source-over 都按预乘 alpha 的
/// `(c × a + 127) / 255` 舍入；合成结果与真实文字纹理的每个颜色通道都不超过 alpha。
@Suite
struct DanmakuTextureCompositionTests {
    @Test
    func outerRingStaysOutsideTheGlyphAndScalesWithCoverage() {
        let dot = TestImage(
            [
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 255, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0
            ],
            width: 5
        )
        // 半点描边在 1x、2x 下的半径是 0.5、1 像素，都膨胀 1 像素，覆盖率分别为 0.5 与 1。
        let oneX = TestImage(zeroCount: 25, width: 5)
        let twoX = TestImage(zeroCount: 25, width: 5)
        #expect(
            DanmakuTextureRasterizer.outerRing(
                alpha: dot.buffer,
                into: oneX.buffer,
                radiusPixels: 0.5
            )
        )
        #expect(
            DanmakuTextureRasterizer.outerRing(
                alpha: dot.buffer,
                into: twoX.buffer,
                radiusPixels: 1
            )
        )
        #expect(oneX.bytes[2 * 5 + 2] == 0)
        #expect(twoX.bytes[2 * 5 + 2] == 0)
        #expect(oneX.bytes[2 * 5 + 1] == 128)
        #expect(twoX.bytes[2 * 5 + 1] == 255)
        #expect(oneX.bytes[1 * 5 + 1] == 128)
        #expect(twoX.bytes[1 * 5 + 1] == 255)
        #expect(oneX.bytes[0] == 0)

        // 3x 下半径 1.5 像素，膨胀 2 像素，覆盖率 0.75：环上取 round((膨胀值 − 原值) × 0.75)。
        let partial = TestImage([0, 0, 0, 200, 100, 0, 0, 0, 0], width: 9)
        let threeX = TestImage(zeroCount: 9, width: 9)
        #expect(
            DanmakuTextureRasterizer.outerRing(
                alpha: partial.buffer,
                into: threeX.buffer,
                radiusPixels: 1.5
            )
        )
        #expect(threeX.bytes == [0, 150, 150, 0, 75, 150, 75, 0, 0])

        let adjacent = TestImage(
            [
                0, 0, 0, 0, 0,
                0, 255, 255, 255, 0,
                0, 0, 0, 0, 0
            ],
            width: 5
        )
        let union = TestImage(zeroCount: 15, width: 5)
        #expect(
            DanmakuTextureRasterizer.outerRing(
                alpha: adjacent.buffer,
                into: union.buffer,
                radiusPixels: 1
            )
        )
        #expect(union.bytes[1 * 5 + 1] == 0)
        #expect(union.bytes[1 * 5 + 2] == 0)
        #expect(union.bytes[1 * 5 + 3] == 0)
    }

    @Test
    func onePointTentShadowIsZeroOffsetAndSymmetricAtOneAndTwoX() {
        var source = [UInt8](repeating: 0, count: 25)
        source[2 * 5 + 2] = 255
        let dot = TestImage(source, width: 5)
        let oneX = TestImage(zeroCount: 25, width: 5)
        let twoX = TestImage(zeroCount: 25, width: 5)
        #expect(DanmakuTextureRasterizer.tentBlur(alpha: dot.buffer, into: oneX.buffer, radius: 1))
        #expect(DanmakuTextureRasterizer.tentBlur(alpha: dot.buffer, into: twoX.buffer, radius: 2))
        let one = oneX.bytes
        let two = twoX.bytes

        #expect(one[2 * 5 + 1] == one[2 * 5 + 3])
        #expect(one[1 * 5 + 2] == one[3 * 5 + 2])
        #expect(two[2 * 5] == two[2 * 5 + 4])
        #expect(two[2] == two[4 * 5 + 2])
        #expect(two[2 * 5 + 2] > two[2 * 5 + 1])
        #expect(two[2 * 5 + 1] > two[2 * 5])
    }

    /// 前景与背景各取一组合法的预乘像素，两两组合后逐通道对照 Alpha.h 的公式。
    @Test
    func sourceOverFollowsThePremultipliedBlendFormula() {
        let samples: [[UInt8]] = [
            [0, 0, 0, 0], [1, 0, 1, 1], [40, 64, 10, 64], [128, 0, 90, 128],
            [200, 199, 0, 200], [3, 250, 128, 254], [255, 255, 255, 255], [0, 0, 0, 255]
        ]
        var foreground: [UInt8] = []
        var background: [UInt8] = []
        for top in samples {
            for bottom in samples {
                foreground += top
                background += bottom
            }
        }
        let width = samples.count * samples.count
        let topImage = TestImage(foreground, width: width, bytesPerPixel: 4)
        let bottomImage = TestImage(background, width: width, bytesPerPixel: 4)

        #expect(DanmakuTextureRasterizer.sourceOver(topImage.buffer, onto: bottomImage.buffer))
        let expected = (0..<foreground.count).map { index -> UInt8 in
            let topAlpha = Int(foreground[index / 4 * 4 + 3])
            return UInt8(
                Int(foreground[index]) + ((255 - topAlpha) * Int(background[index]) + 127) / 255
            )
        }
        #expect(bottomImage.bytes == expected)
    }

    @Test
    func monochromeIsWhiteOrBlackWithTheGivenAlpha() {
        let levels: [UInt8] = [0, 1, 77, 128, 254, 255]
        let alpha = TestImage(levels, width: levels.count)
        let light = TestImage(zeroCount: levels.count * 4, width: levels.count, bytesPerPixel: 4)
        let dark = TestImage(zeroCount: levels.count * 4, width: levels.count, bytesPerPixel: 4)

        #expect(
            DanmakuTextureRasterizer.paintMonochrome(
                alpha: alpha.buffer,
                into: light.buffer,
                isLight: true
            )
        )
        #expect(
            DanmakuTextureRasterizer.paintMonochrome(
                alpha: alpha.buffer,
                into: dark.buffer,
                isLight: false
            )
        )
        #expect(light.bytes == levels.flatMap { [$0, $0, $0, $0] })
        #expect(dark.bytes == levels.flatMap { [0, 0, 0, $0] })
    }

    /// 每列的颜色取自文字列范围上的渐变位置，再按 alpha 预乘；alpha 为 0 的像素整个透明。
    @Test
    func vipGradientPremultipliesEachColumnColor() {
        let width = 12
        let columns = 2..<10
        let alphaRows: [UInt8] = (0..<(width * 2)).map { UInt8(($0 * 37) % 256) }
        let alpha = TestImage(alphaRows, width: width)
        let image = TestImage(zeroCount: alphaRows.count * 4, width: width, bytesPerPixel: 4)

        #expect(
            DanmakuTextureRasterizer.paintGradient(
                alpha: alpha.buffer,
                into: image.buffer,
                columns: columns
            )
        )
        let expected = alphaRows.enumerated().flatMap { index, value -> [UInt8] in
            let color = DanmakuTextureRasterizer.vipGradientColor(
                at: Double(index % width - columns.lowerBound) / Double(columns.count)
            )
            let premultiply = { (channel: UInt8) in UInt8((Int(channel) * Int(value) + 127) / 255) }
            return [
                premultiply(color.red), premultiply(color.green), premultiply(color.blue), value
            ]
        }
        #expect(image.bytes == expected)
    }

    /// 不透明白色方块：方块内保持字形原样，紧贴的一圈是整像素描边，再往外只剩阴影。
    @Test(arguments: [false, true])
    func compositeKeepsTheGlyphAndOutlinesItOutside(isLight: Bool) throws {
        let width = 13
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        for row in 5...7 {
            for column in 5...7 {
                let offset = (row * width + column) * 4
                pixels.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
            }
        }
        let fill = try #require(malloc(pixels.count))
        pixels.withUnsafeBytes { fill.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        let data = try #require(
            DanmakuTextureRasterizer.composite(
                fill: fill,
                width: width,
                height: width,
                outlineRadiusPixels: 1,
                shadowRadiusPixels: 2,
                isLightDecoration: isLight,
                gradientColumns: nil
            )
        )
        let result = [UInt8](data)
        func pixel(row: Int, column: Int) -> [UInt8] {
            let offset = (row * width + column) * 4
            return Array(result[offset..<(offset + 4)])
        }
        let ink: UInt8 = isLight ? 255 : 0

        #expect(pixel(row: 6, column: 6) == [255, 255, 255, 255])
        #expect(pixel(row: 6, column: 4) == [ink, ink, ink, 255])
        #expect(pixel(row: 4, column: 4) == [ink, ink, ink, 255])
        let shadow = pixel(row: 6, column: 3)
        #expect(shadow[3] > 0 && shadow[3] < 255)
        #expect(isPremultiplied(result))
    }

    @Test(arguments: [1.0, 2.0, 3.0])
    func rasterizedTexturesArePremultiplied(backingScale: Double) throws {
        let keys: [(String, UInt32, DanmakuColorStyle)] = [
            ("中文 日本語 한국어 Latin 😀 #", 0xFFFFFF, .solid),
            ("前方高能！！！", 0x000000, .solid),
            ("awsl 😂👍🏻", 0xFE0302, .solid),
            ("大会员 VIP", DanmakuTextureRasterizer.vipGradientFillRGB, .vipGradient)
        ]
        for (text, colorRGB, colorStyle) in keys {
            let key = DanmakuTextureCacheKey(
                text: text,
                fontSize: 25,
                isHighLike: false,
                colorRGB: colorRGB,
                colorStyle: colorStyle,
                backingScale: backingScale
            )
            let texture = try #require(DanmakuTextureRasterizer.rasterize(key: key))
            let bytes = [UInt8](texture.pixels)
            #expect(bytes.count == texture.byteCost)
            #expect(isPremultiplied(bytes))
            #expect(bytes.contains(255))
        }
    }

    private func isPremultiplied(_ rgba: [UInt8]) -> Bool {
        stride(from: 0, to: rgba.count, by: 4).allSatisfy { offset in
            rgba[offset..<(offset + 3)].allSatisfy { $0 <= rgba[offset + 3] }
        }
    }
}

/// 测试里手造的一块 vImage 缓冲：拷入给定字节，读回当前字节，释放时归还内存。
private final class TestImage {
    let buffer: vImage_Buffer
    private let byteCount: Int

    init(_ bytes: [UInt8], width: Int, bytesPerPixel: Int = 1) {
        precondition(!bytes.isEmpty && bytes.count % (width * bytesPerPixel) == 0)
        let data = malloc(bytes.count)!
        bytes.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        byteCount = bytes.count
        buffer = vImage_Buffer(
            data: data,
            height: vImagePixelCount(bytes.count / (width * bytesPerPixel)),
            width: vImagePixelCount(width),
            rowBytes: width * bytesPerPixel
        )
    }

    convenience init(zeroCount: Int, width: Int, bytesPerPixel: Int = 1) {
        self.init(
            [UInt8](repeating: 0, count: zeroCount),
            width: width,
            bytesPerPixel: bytesPerPixel
        )
    }

    var bytes: [UInt8] {
        [UInt8](UnsafeRawBufferPointer(start: buffer.data, count: byteCount))
    }

    deinit {
        free(buffer.data)
    }
}
