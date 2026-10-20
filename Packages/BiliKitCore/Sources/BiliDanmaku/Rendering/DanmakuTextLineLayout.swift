import AppKit
import BiliModels
import CoreText
import Foundation

/// 决定弹幕纹理尺寸的输入：文字、归一化字号与 backing scale；颜色与描边样式不影响排版，不在其中。
///
/// 由 `DanmakuTextureRasterizer.measureKey` 归一化后生成；纹理缓存 key 在它之上再加颜色。
struct DanmakuTextMeasureKey: Hashable, Sendable {
    let text: String
    let fontSize: Double
    let backingScale: Double
}

/// 一行弹幕文字的排版结果与纹理像素尺寸。
///
/// 车道布局的测量与纹理栅格化都从这里取尺寸：布局用的宽高与上屏纹理的宽高因此逐像素一致，滚动弹幕的
/// 速度与追尾判断不会因两边各算一份而漂移。
struct DanmakuTextLineLayout {
    let line: CTLine
    let descent: CGFloat
    let widthPixels: Int
    let heightPixels: Int
    let paddingPixels: Int
    let outlineRadiusPixels: Double
    let shadowRadiusPixels: Int

    var bytesPerRow: Int { widthPixels * 4 }
}

extension DanmakuTextureRasterizer {
    /// 校验文字与 scale 并归一字号；文字为空或过长、字号或 scale 无效时为 nil。
    static func measureKey(
        event: DanmakuEvent,
        backingScale: Double
    ) -> DanmakuTextMeasureKey? {
        guard !event.text.isEmpty,
            event.text.utf16.count <= maximumTextUTF16Length,
            event.fontSize.isFinite,
            backingScale.isFinite,
            backingScale >= 1,
            backingScale <= maximumBackingScale
        else {
            return nil
        }
        return DanmakuTextMeasureKey(
            text: event.text,
            fontSize: DanmakuEvent.normalizedFontSize(event.fontSize),
            backingScale: backingScale
        )
    }

    /// 只排版、不栅格化，给出与 `rasterize` 完全相同的纹理 point 尺寸；排版失败或纹理超出尺寸与字节
    /// 上限时为 nil（栅格化同样会拒绝，这条弹幕不参与车道布局）。
    ///
    /// 线程安全，车道布局在后台调用。
    static func measure(_ key: DanmakuTextMeasureKey) -> DanmakuTextMetrics? {
        guard let layout = lineLayout(key, foreground: nil) else { return nil }
        return DanmakuTextMetrics(
            width: Double(layout.widthPixels) / key.backingScale,
            height: Double(layout.heightPixels) / key.backingScale
        )
    }

    /// 测量与栅格化共用的排版：Core Text 排出一行，四周留出描边与阴影的扩散，并按像素上限校验。
    ///
    /// `foreground` 只影响字形颜色，不影响排版；测量时传 nil。
    static func lineLayout(
        _ key: DanmakuTextMeasureKey,
        foreground: CGColor?
    ) -> DanmakuTextLineLayout? {
        let font = NSFont.systemFont(
            ofSize: CGFloat(key.fontSize),
            weight: fontWeight
        )
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        if let foreground {
            attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] =
                foreground
        }
        let attributed = NSAttributedString(string: key.text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        )
        let height = ascent + descent + leading
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }

        let scale = CGFloat(key.backingScale)
        let outlineRadiusPixels = outlineWidthPoints * key.backingScale
        let shadowRadiusPixels =
            shadowRadiusPoints > 0
            ? max(
                1,
                Int((shadowRadiusPoints * key.backingScale).rounded())
            ) : 0
        // 四周留白要容纳描边与阴影的扩散，至少 4 像素。
        let paddingPixels = max(
            4,
            Int(ceil(outlineRadiusPixels)) + shadowRadiusPixels + 2
        )
        let widthPixels = Int(ceil(width * scale)) + paddingPixels * 2
        let heightPixels = Int(ceil(height * scale)) + paddingPixels * 2
        let bytesPerRow = widthPixels * 4
        guard widthPixels > 0,
            heightPixels > 0,
            widthPixels <= maximumWidthPixels,
            heightPixels <= maximumHeightPixels,
            bytesPerRow <= Int.max / heightPixels,
            bytesPerRow * heightPixels <= maximumTextureByteCost
        else {
            return nil
        }
        return DanmakuTextLineLayout(
            line: line,
            descent: descent,
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            paddingPixels: paddingPixels,
            outlineRadiusPixels: outlineRadiusPixels,
            shadowRadiusPixels: shadowRadiusPixels
        )
    }
}

/// 车道布局的测量缓存：同一文字、字号与 scale 只排版一次，测量失败也记下。
///
/// 值类型，由 `DanmakuLayoutCoordinator` 持有；一次布局任务运行时整份移交给后台任务、完成后交回，
/// 同一时刻只有一个持有者，不需要锁。
struct DanmakuTextMeasurementCache: Sendable {
    /// 缓存的条目上限，超出时整份清空重来。
    ///
    /// 三个满载分段约 6 万条弹幕，其中重复文字很多；这个上限足够覆盖缓存的分段，每条只占几十字节。
    /// 调小会让设置变化后的重新布局更常重新排版，调大只多占内存。
    static let maximumEntryCount = 65_536

    private var metricsByKey: [DanmakuTextMeasureKey: DanmakuTextMetrics?] = [:]

    /// 这条弹幕在 `backingScale` 下的纹理 point 尺寸；文字无效或纹理超限时为 nil。
    mutating func metrics(
        for event: DanmakuEvent,
        backingScale: Double
    ) -> DanmakuTextMetrics? {
        guard
            let key = DanmakuTextureRasterizer.measureKey(
                event: event,
                backingScale: backingScale
            )
        else {
            return nil
        }
        if let cached = metricsByKey[key] {
            return cached
        }
        if metricsByKey.count >= Self.maximumEntryCount {
            metricsByKey.removeAll(keepingCapacity: true)
        }
        let metrics = DanmakuTextureRasterizer.measure(key)
        metricsByKey[key] = metrics
        return metrics
    }
}
