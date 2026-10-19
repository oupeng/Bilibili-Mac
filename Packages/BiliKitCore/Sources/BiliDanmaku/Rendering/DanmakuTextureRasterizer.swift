import Accelerate
import AppKit
import BiliModels
import CoreText
import Foundation

/// 决定纹理像素的全部输入，也是纹理缓存的 key；由 `DanmakuTextureRasterizer.key` 归一化后生成。
struct DanmakuTextureCacheKey: Hashable, Sendable {
    let text: String
    let fontSize: Double
    let colorRGB: UInt32
    let colorStyle: DanmakuColorStyle
    let backingScale: Double
}

/// 栅格化好的不可变像素：sRGB、预乘 alpha、按字节 RGBA 排列，由 renderer 在 MainActor 上包成
/// `CGImage`。
///
/// `byteCost` 计入缓存与已上屏纹理的字节上限；`metrics` 是含留白的 point 尺寸。
struct DanmakuTexturePayload: Sendable, Equatable {
    let pixels: Data
    let widthPixels: Int
    let heightPixels: Int
    let bytesPerRow: Int
    let backingScale: Double

    var byteCost: Int { bytesPerRow * heightPixels }

    var metrics: DanmakuTextMetrics {
        DanmakuTextMetrics(
            width: Double(widthPixels) / backingScale,
            height: Double(heightPixels) / backingScale
        )
    }
}

/// 把一条弹幕栅格化为带描边与阴影的纹理：Core Text 排版，vImage 生成描边与阴影，最后按预乘 alpha
/// 合成。
///
/// 在纹理准备 owner 的后台队列调用，不读写共享状态。彩色字形（emoji）保留 Core Text 填充的 RGBA；
/// 描边与阴影的深浅只按弹幕声明的颜色、对整行字形的并集 mask 决定一次，不逐字形自适应，所以 emoji
/// 与文字混排时不会被压成同一种填充色。
enum DanmakuTextureRasterizer {
    /// 文本长度上限（UTF-16 单元）；更长的弹幕按 `invalidInput` 拒绝，不截断。
    static let maximumTextUTF16Length = 512
    /// 纹理像素宽度上限；超出的弹幕按 `oversized` 拒绝，不缩小显示。
    static let maximumWidthPixels = 8_192
    /// 纹理像素高度上限；超出时同样按 `oversized` 拒绝。
    static let maximumHeightPixels = 512
    /// 单个纹理的字节上限，也是纹理缓存的单项上限；宽度接近像素上限的长文本主要受它约束。
    static let maximumTextureByteCost = 8 * 1_024 * 1_024
    /// 支持的最大 backing scale；呈现控制器归一时把更大的值夹到这里。
    static let maximumBackingScale = 4.0
    /// 宿主还没报告窗口 backing scale 时的初值，也是非有限值的回退：Retina 屏是 2。
    static let defaultBackingScale = 2.0

    /// 窗口报告的 backing scale 归一到 1...`maximumBackingScale`，非有限值回退到 `defaultBackingScale`。
    ///
    /// 只由呈现控制器在 surface 更新时调用一次，再把结果交给 renderer 与 materializer；两边不再各自
    /// 归一，否则一边认为 scale 没变、另一边已经换了栅格倍率。
    static func normalizedBackingScale(_ scale: Double) -> Double {
        scale.isFinite ? min(max(scale, 1), maximumBackingScale) : defaultBackingScale
    }
    /// 描边宽度（point），由字形 alpha 向外膨胀得到。
    static let outlineWidthPoints = 0.5
    /// 字重与阴影是产品固定视觉，不随设置变化；阴影是预烘焙 tent convolution 的 point 半径。
    static let fontWeight = NSFont.Weight.semibold
    static let shadowRadiusPoints = 1.0
    /// 描边与阴影取浅色的判定阈值：文字颜色的相对亮度低于它时用浅色，否则用深色。
    ///
    /// 0.179 是与黑色、白色对比度相等的亮度分界（WCAG 相对亮度与对比度公式）。
    static let lightInkRelativeLuminanceThreshold = 0.179
    /// 大会员彩色弹幕的填充色；描边是 `vipGradientStops`。
    static let vipGradientFillRGB: UInt32 = 0xFF_FFFF
    /// 大会员渐变描边的色标：B 站 60001 描边贴图横向五等分采样，从文字左缘到右缘线性插值。
    static let vipGradientStops: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (0xF2, 0x50, 0x9E),
        (0xD4, 0x59, 0xA6),
        (0x90, 0x6E, 0xB6),
        (0x51, 0x81, 0xC5),
        (0x30, 0x8B, 0xCD)
    ]

    static func key(
        event: DanmakuEvent,
        backingScale: Double
    ) -> DanmakuTextureCacheKey? {
        guard let measureKey = measureKey(event: event, backingScale: backingScale) else {
            return nil
        }
        return DanmakuTextureCacheKey(
            text: measureKey.text,
            fontSize: measureKey.fontSize,
            colorRGB: event.colorStyle == .vipGradient
                ? vipGradientFillRGB : event.colorRGB & 0x00FF_FFFF,
            colorStyle: event.colorStyle,
            backingScale: measureKey.backingScale
        )
    }

    static func rasterize(
        key: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        let scale = CGFloat(key.backingScale)
        let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let components = rgbComponents(key.colorRGB)
        let foreground = CGColor(
            srgbRed: components.red,
            green: components.green,
            blue: components.blue,
            alpha: 1
        )
        guard
            let layout = lineLayout(
                DanmakuTextMeasureKey(
                    text: key.text,
                    fontSize: key.fontSize,
                    backingScale: key.backingScale
                ),
                foreground: foreground
            )
        else {
            return nil
        }
        let widthPixels = layout.widthPixels
        let heightPixels = layout.heightPixels
        let bytesPerRow = layout.bytesPerRow
        let paddingPixels = layout.paddingPixels
        let outlineRadiusPixels = layout.outlineRadiusPixels
        let shadowRadiusPixels = layout.shadowRadiusPixels
        let line = layout.line
        let descent = layout.descent

        var fill = [UInt8](repeating: 0, count: bytesPerRow * heightPixels)
        let drewLine = fill.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: widthPixels,
                    height: heightPixels,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo.rawValue
                )
            else {
                return false
            }
            context.scaleBy(x: scale, y: scale)
            let padding = CGFloat(paddingPixels) / scale
            context.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(line, context)
            return true
        }
        guard drewLine else { return nil }

        let fillAlpha = alpha(from: fill)
        let ringAlpha = outerRing(
            alpha: fillAlpha,
            width: widthPixels,
            height: heightPixels,
            radiusPixels: outlineRadiusPixels
        )
        let isLightDecoration = decorationIsLight(colorRGB: key.colorRGB)
        let ring: [UInt8]
        switch key.colorStyle {
        case .solid:
            ring = monochromePixels(alpha: ringAlpha, isLight: isLightDecoration)
        case .vipGradient:
            ring = vipGradientPixels(
                alpha: ringAlpha,
                width: widthPixels,
                textStartX: paddingPixels,
                textEndX: widthPixels - paddingPixels
            )
        }
        let decorated = sourceOver(foreground: fill, background: ring)
        guard shadowRadiusPixels > 0 else {
            return DanmakuTexturePayload(
                pixels: Data(decorated),
                widthPixels: widthPixels,
                heightPixels: heightPixels,
                bytesPerRow: bytesPerRow,
                backingScale: key.backingScale
            )
        }
        let blurredAlpha = tentBlur(
            alpha: alpha(from: decorated),
            width: widthPixels,
            height: heightPixels,
            radius: shadowRadiusPixels
        )
        let shadow = monochromePixels(
            alpha: blurredAlpha,
            isLight: isLightDecoration
        )
        let baked = sourceOver(foreground: decorated, background: shadow)
        return DanmakuTexturePayload(
            pixels: Data(baked),
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            bytesPerRow: bytesPerRow,
            backingScale: key.backingScale
        )
    }

    /// 字形 alpha 向外膨胀 `radiusPixels` 后减去原 alpha，得到只在字形外侧的描边环；
    /// 半径不足整像素时按比例减弱。
    static func outerRing(
        alpha: [UInt8],
        width: Int,
        height: Int,
        radiusPixels: Double
    ) -> [UInt8] {
        precondition(alpha.count == width * height)
        guard !alpha.isEmpty, radiusPixels > 0 else {
            return [UInt8](repeating: 0, count: alpha.count)
        }
        let radius = max(1, Int(ceil(radiusPixels)))
        var source = alpha
        var dilated = [UInt8](repeating: 0, count: alpha.count)
        let kernelSize = vImagePixelCount(radius * 2 + 1)
        let error = source.withUnsafeMutableBytes { sourceBuffer in
            dilated.withUnsafeMutableBytes { destinationBuffer in
                var sourceImage = vImage_Buffer(
                    data: sourceBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                return vImageMax_Planar8(
                    &sourceImage,
                    &destinationImage,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        guard error == kvImageNoError else {
            return [UInt8](repeating: 0, count: alpha.count)
        }
        let edgeCoverage = min(radiusPixels / Double(radius), 1)
        return zip(dilated, alpha).map { expanded, original in
            guard expanded > original else { return 0 }
            return UInt8(
                min(
                    255,
                    Int((Double(expanded - original) * edgeCoverage).rounded())
                )
            )
        }
    }

    /// 阴影用的 tent 模糊；vImage 失败时原样返回。
    static func tentBlur(
        alpha: [UInt8],
        width: Int,
        height: Int,
        radius: Int
    ) -> [UInt8] {
        precondition(alpha.count == width * height)
        guard !alpha.isEmpty, radius > 0 else { return alpha }
        var source = alpha
        var result = [UInt8](repeating: 0, count: alpha.count)
        let kernelSize = UInt32(radius * 2 + 1)
        let error = source.withUnsafeMutableBytes { sourceBuffer in
            result.withUnsafeMutableBytes { destinationBuffer in
                var sourceImage = vImage_Buffer(
                    data: sourceBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destinationBuffer.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                return vImageTentConvolve_Planar8(
                    &sourceImage,
                    &destinationImage,
                    nil,
                    0,
                    0,
                    kernelSize,
                    kernelSize,
                    0,
                    vImage_Flags(kvImageEdgeExtend)
                )
            }
        }
        return error == kvImageNoError ? result : alpha
    }

    static func alpha(from pixels: [UInt8]) -> [UInt8] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }

    /// 用单一灰阶（浅为白、深为黑）和给定 alpha 生成预乘 RGBA。
    static func monochromePixels(
        alpha: [UInt8],
        isLight: Bool
    ) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: alpha.count * 4)
        for index in alpha.indices {
            let value = alpha[index]
            let offset = index * 4
            let channel = isLight ? value : 0
            pixels[offset] = channel
            pixels[offset + 1] = channel
            pixels[offset + 2] = channel
            pixels[offset + 3] = value
        }
        return pixels
    }

    /// 按列着色的渐变描边（预乘 alpha）；文字左缘以左取首个色标，右缘以右取末个色标。
    static func vipGradientPixels(
        alpha: [UInt8],
        width: Int,
        textStartX: Int,
        textEndX: Int
    ) -> [UInt8] {
        precondition(width > 0 && alpha.count % width == 0)
        let span = Double(max(1, textEndX - textStartX))
        let columns = (0..<width).map { column in
            vipGradientColor(at: Double(column - textStartX) / span)
        }
        var pixels = [UInt8](repeating: 0, count: alpha.count * 4)
        for index in alpha.indices where alpha[index] > 0 {
            let value = Int(alpha[index])
            let color = columns[index % width]
            let offset = index * 4
            pixels[offset] = UInt8((Int(color.red) * value + 127) / 255)
            pixels[offset + 1] = UInt8((Int(color.green) * value + 127) / 255)
            pixels[offset + 2] = UInt8((Int(color.blue) * value + 127) / 255)
            pixels[offset + 3] = UInt8(value)
        }
        return pixels
    }

    /// 渐变上 `position`（0 为左缘、1 为右缘，超出时取端点）处的颜色。
    static func vipGradientColor(
        at position: Double
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let stops = vipGradientStops
        let scaled = min(max(position, 0), 1) * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let fraction = scaled - Double(lower)
        func mix(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8((Double(from) + (Double(to) - Double(from)) * fraction).rounded())
        }
        let from = stops[lower]
        let to = stops[lower + 1]
        return (mix(from.red, to.red), mix(from.green, to.green), mix(from.blue, to.blue))
    }

    /// 预乘 alpha 的 source-over 合成：`foreground` 叠在 `background` 之上。
    static func sourceOver(
        foreground: [UInt8],
        background: [UInt8]
    ) -> [UInt8] {
        precondition(foreground.count == background.count)
        var result = background
        for offset in stride(from: 0, to: result.count, by: 4) {
            let foregroundAlpha = Int(foreground[offset + 3])
            let inverseAlpha = 255 - foregroundAlpha
            for channel in 0..<3 {
                result[offset + channel] = UInt8(
                    min(
                        255,
                        Int(foreground[offset + channel])
                            + (Int(background[offset + channel])
                                * inverseAlpha + 127) / 255
                    )
                )
            }
            result[offset + 3] = UInt8(
                min(
                    255,
                    foregroundAlpha
                        + (Int(background[offset + 3]) * inverseAlpha + 127)
                        / 255
                )
            )
        }
        return result
    }

    private static func decorationIsLight(colorRGB: UInt32) -> Bool {
        relativeLuminance(rgbComponents(colorRGB))
            < lightInkRelativeLuminanceThreshold
    }

    private static func rgbComponents(
        _ colorRGB: UInt32
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let rgb = colorRGB & 0x00FF_FFFF
        return (
            CGFloat((rgb >> 16) & 0xFF) / 255,
            CGFloat((rgb >> 8) & 0xFF) / 255,
            CGFloat(rgb & 0xFF) / 255
        )
    }

    private static func relativeLuminance(
        _ components: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> CGFloat {
        0.2126 * linearized(components.red)
            + 0.7152 * linearized(components.green)
            + 0.0722 * linearized(components.blue)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
    ).union(.byteOrder32Big)
}
