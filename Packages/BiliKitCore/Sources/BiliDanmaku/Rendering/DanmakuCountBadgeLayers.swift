import AppKit
import QuartzCore

/// 计数胶囊的 Core Animation 层：半透明黑底胶囊，里面是“×”与逐位数字，条数随媒体时间切换并跳一下。
///
/// 由 `CoreAnimationDanmakuRenderer` 在挂上或更新一条弹幕时调用，胶囊作为子层挂在正文 layer 右侧。子层的局部时间
/// 就是媒体时间（继承时钟层），所以条数、胶囊宽度与跳动都写成从弹幕自己的时间点开始、`removedOnCompletion` 为
/// false 的关键帧动画：画面是媒体时间的纯函数，暂停、seek 与倍速都由时钟层处理，不随对齐步长刷新。
///
/// 拥有“×”与 0–9 的白色字形图缓存（按字号与 backing scale），在主线程按需生成一次后复用。字形图一共只有几十张
/// 小图，不经纹理准备 owner，不占正文纹理的准备名额，也不计入在屏纹理字节上限。
@MainActor
final class DanmakuCountBadgeLayers {
    /// 胶囊子层的名字；更新或移除时按它找到旧胶囊。
    static let layerName = "danmaku.countBadge"
    /// 条数增加时胶囊的最大放大倍数。
    static let pulseScale = 1.25
    /// 一次跳动的时长（媒体秒）；倍速时随播放一起变快，相邻两条到达比它更近时后一条不再单独跳。
    static let pulseSeconds = 0.15

    private struct GlyphKey: Hashable {
        let fontSize: Double
        let backingScale: Double
    }

    private var glyphs: [GlyphKey: [Character: CGImage]] = [:]

    /// 换掉 `layer` 上的旧胶囊；`badge` 为 nil 或条数在弹幕离场前都不会变化时只移除。
    ///
    /// `textWidth` 与 `height` 是正文 layer 的尺寸，胶囊挂在正文右缘之外、纵向居中；`beginTime` 与 `duration` 是
    /// 弹幕动画的开始时间与时长，关键帧按到达时间在其中的比例排。`reducesMotion` 时不跳。
    func replaceBadge(
        on layer: CALayer,
        badge: DanmakuCountBadge?,
        textWidth: Double,
        height: Double,
        admittedAtSeconds: Double,
        beginTime: CFTimeInterval,
        duration: Double,
        backingScale: Double,
        reducesMotion: Bool
    ) {
        for sublayer in layer.sublayers ?? [] where sublayer.name == Self.layerName {
            sublayer.removeAllAnimations()
            sublayer.removeFromSuperlayer()
        }
        guard let badge, duration > 0 else { return }
        let steps = Self.countSteps(
            badge: badge,
            admittedAtSeconds: admittedAtSeconds,
            duration: duration
        )
        guard let firstStep = steps.first else { return }

        let geometry = DanmakuCountBadgeGeometry.geometry(forFontSize: badge.fontSize)
        let glyphImages = glyphImages(for: geometry, fontSize: badge.fontSize, scale: backingScale)
        let finalDigits = String(steps.last?.count ?? badge.finalCount).count

        let pill = CALayer()
        pill.name = Self.layerName
        pill.actions = CoreAnimationDanmakuRenderer.disabledActions
        pill.anchorPoint = CGPoint(x: 0, y: 0.5)
        pill.position = CGPoint(x: textWidth + Double(geometry.spacing), y: height / 2)
        pill.bounds = CGRect(
            x: 0,
            y: 0,
            width: geometry.width(forCount: firstStep.count),
            height: geometry.height
        )
        pill.cornerRadius = geometry.height / 2
        pill.masksToBounds = true
        pill.backgroundColor =
            NSColor.black.withAlphaComponent(DanmakuCountBadgeGeometry.backgroundOpacity).cgColor
        // 模型不透明度为 0：第二条到达之前与动画区间之外都看不见，到达后由动画撑起。
        pill.opacity = 0

        let timesLayer = glyphLayer(
            image: glyphImages[DanmakuCountBadgeGeometry.timesSign],
            x: geometry.horizontalPadding,
            width: geometry.timesSignWidth,
            geometry: geometry,
            scale: backingScale
        )
        pill.addSublayer(timesLayer)
        for slot in 0..<finalDigits {
            let digitLayer = glyphLayer(
                image: Self.digit(at: slot, of: firstStep.count).flatMap { glyphImages[$0] },
                x: geometry.horizontalPadding + geometry.timesSignWidth
                    + geometry.digitWidth * CGFloat(slot),
                width: geometry.digitWidth,
                geometry: geometry,
                scale: backingScale
            )
            // 位数少于这一位时内容留着上一个数字，由胶囊的宽度裁掉。
            var values: [Any] = []
            var keyTimes: [Double] = []
            var shown: Character?
            for step in steps {
                let digit = Self.digit(at: slot, of: step.count) ?? shown
                guard let digit, digit != shown, let image = glyphImages[digit] else { continue }
                values.append(image)
                keyTimes.append(values.count == 1 ? 0 : step.fraction)
                shown = digit
            }
            add(
                discrete(keyPath: "contents", values: values, keyTimes: keyTimes),
                to: digitLayer,
                beginTime: beginTime,
                duration: duration
            )
            pill.addSublayer(digitLayer)
        }

        add(
            discrete(keyPath: "opacity", values: [0, 1], keyTimes: [0, firstStep.fraction]),
            to: pill,
            beginTime: beginTime,
            duration: duration
        )
        var widths: [Any] = []
        var widthTimes: [Double] = []
        var widthDigits = 0
        for step in steps where String(step.count).count != widthDigits {
            widthDigits = String(step.count).count
            widths.append(geometry.width(forCount: step.count))
            widthTimes.append(widths.count == 1 ? 0 : step.fraction)
        }
        add(
            discrete(keyPath: "bounds.size.width", values: widths, keyTimes: widthTimes),
            to: pill,
            beginTime: beginTime,
            duration: duration
        )
        if !reducesMotion, let pulse = Self.pulse(steps: steps, duration: duration) {
            add(pulse, to: pill, beginTime: beginTime, duration: duration)
        }
        layer.addSublayer(pill)
    }

    /// 条数在弹幕在屏期间的每一次变化：比例是到达时间在动画区间里的位置，同一时刻到达的几条合成一步。
    ///
    /// 到达时间不早于离场的不显示；空数组表示条数在屏期间不会变化，不挂胶囊。
    static func countSteps(
        badge: DanmakuCountBadge,
        admittedAtSeconds: Double,
        duration: Double
    ) -> [(fraction: Double, count: Int)] {
        var steps: [(fraction: Double, count: Int)] = []
        for (offset, arrival) in badge.laterArrivalTimes.enumerated() {
            let fraction = max(0, (arrival - admittedAtSeconds) / duration)
            guard fraction < 1 else { break }
            let count = offset + 2
            if let last = steps.last, last.fraction == fraction {
                steps[steps.count - 1].count = count
            } else {
                steps.append((fraction, count))
            }
        }
        return steps
    }

    /// 每一步开始时从 1 放大到 `pulseScale` 再回到 1；与上一次跳动重叠的步不再单独跳。
    private static func pulse(
        steps: [(fraction: Double, count: Int)],
        duration: Double
    ) -> CAKeyframeAnimation? {
        let span = pulseSeconds / duration
        var values: [Double] = [1]
        var keyTimes: [Double] = [0]
        var previousEnd = 0.0
        for step in steps where step.fraction >= previousEnd {
            let end = min(step.fraction + span, 1)
            values += [1, pulseScale, 1]
            keyTimes += [step.fraction, min(step.fraction + span / 2, 1), end]
            previousEnd = end
        }
        guard values.count > 1 else { return nil }
        values.append(1)
        keyTimes.append(1)
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = values
        animation.keyTimes = keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = .linear
        return animation
    }

    /// `count` 的十进制第 `slot` 位（从左数）；位数不够时为 nil。
    private static func digit(at slot: Int, of count: Int) -> Character? {
        let digits = Array(String(count))
        return slot < digits.count ? digits[slot] : nil
    }

    /// 离散关键帧：第 i 个值从 `keyTimes[i]` 起生效直到下一个；Core Animation 要求离散模式的 keyTimes 比 values
    /// 多一项且以 1 结尾。
    private func discrete(
        keyPath: String,
        values: [Any],
        keyTimes: [Double]
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = (keyTimes + [1]).map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        return animation
    }

    private func add(
        _ animation: CAKeyframeAnimation,
        to layer: CALayer,
        beginTime: CFTimeInterval,
        duration: Double
    ) {
        animation.beginTime = beginTime
        animation.duration = duration
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: animation.keyPath)
    }

    private func glyphLayer(
        image: CGImage?,
        x: CGFloat,
        width: CGFloat,
        geometry: DanmakuCountBadgeGeometry,
        scale: Double
    ) -> CALayer {
        let layer = CALayer()
        layer.actions = CoreAnimationDanmakuRenderer.disabledActions
        layer.anchorPoint = .zero
        layer.position = CGPoint(x: x, y: 0)
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: geometry.height)
        layer.contents = image
        layer.contentsScale = CGFloat(scale)
        layer.contentsGravity = .resize
        return layer
    }

    /// 乘号与 0–9 的白色字形图。
    ///
    /// 每张一个字符格宽、胶囊高，字形按大写字母高度纵向居中。
    private func glyphImages(
        for geometry: DanmakuCountBadgeGeometry,
        fontSize: Double,
        scale: Double
    ) -> [Character: CGImage] {
        let key = GlyphKey(fontSize: fontSize, backingScale: scale)
        if let cached = glyphs[key] { return cached }
        let font = geometry.glyphFont
        var images: [Character: CGImage] = [:]
        for character in [DanmakuCountBadgeGeometry.timesSign] + Array("0123456789") {
            let cellWidth =
                character == DanmakuCountBadgeGeometry.timesSign
                ? geometry.timesSignWidth : geometry.digitWidth
            images[character] = Self.renderGlyph(
                character,
                font: font,
                cellWidth: cellWidth,
                height: geometry.height,
                scale: CGFloat(scale)
            )
        }
        glyphs[key] = images
        return images
    }

    private static func renderGlyph(
        _ character: Character,
        font: NSFont,
        cellWidth: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> CGImage? {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: String(character),
                attributes: [.font: font, .foregroundColor: NSColor.white.cgColor]
            )
        )
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard
            let context = CGContext(
                data: nil,
                width: Int(ceil(cellWidth * scale)),
                height: Int(ceil(height * scale)),
                bitsPerComponent: DanmakuTexturePayload.bitsPerComponent,
                bytesPerRow: 0,
                space: DanmakuTexturePayload.colorSpace,
                bitmapInfo: DanmakuTexturePayload.bitmapInfo.rawValue
            )
        else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(
            x: (cellWidth - advance) / 2,
            y: (height - font.capHeight) / 2
        )
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
