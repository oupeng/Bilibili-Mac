import AppKit
import BiliModels
import CoreGraphics

/// 高赞弹幕开头的赞图标：SF Symbol 预先栅格化成 alpha 遮罩，栅格化时按弹幕颜色填充，再与文字一起走描边与阴影。
///
/// 三档字号各一份，进程内首次使用时生成、之后只读，测量与栅格化在任意后台线程共用；不随纹理缓存淘汰。
/// 尺寸与基线位置都在这里定，测量和绘制取同一份，纹理宽度与车道布局不会错开。
struct DanmakuHighLikeIcon: Sendable {
    /// 与文字同字重、small 档：符号的对齐框正好是大写字母高，不撑高行高，弹幕纹理高度不因图标变化。
    static let symbolName = "hand.thumbsup.fill"
    static let symbolScale = NSImage.SymbolScale.small
    /// 图标与文字之间的间距占字号的比例。
    static let spacingFontSizeRatio = 0.15
    /// 遮罩按支持的最大 backing scale 栅格化，低倍率屏幕绘制时由 Core Graphics 缩小。
    static let maskScale = DanmakuTextureRasterizer.maximumBackingScale

    /// 图标遮罩：符号形状在 alpha 通道。
    let mask: CGImage
    /// 图标的 point 尺寸。
    let size: CGSize
    /// 图标底边在基线以下的 point 距离：符号对齐框的底边落在文字基线上。
    let descentBelowBaseline: CGFloat
    /// 图标右侧到文字起点的 point 间距。
    let spacing: CGFloat

    /// 对应字号的图标。
    ///
    /// 字号须已经过 `DanmakuEvent.normalizedFontSize`。符号不可用时为 nil，高赞弹幕照常只画文字。
    static func icon(forFontSize fontSize: Double) -> DanmakuHighLikeIcon? {
        iconsByFontSize[fontSize] ?? nil
    }

    private static let iconsByFontSize: [Double: DanmakuHighLikeIcon?] = Dictionary(
        uniqueKeysWithValues: DanmakuEvent.supportedFontSizes.map { ($0, make(fontSize: $0)) }
    )

    private static func make(fontSize: Double) -> DanmakuHighLikeIcon? {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: CGFloat(fontSize),
            weight: DanmakuTextureRasterizer.fontWeight,
            scale: symbolScale
        )
        guard
            let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else {
            return nil
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard
            let mask = image.cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: [.ctm: AffineTransform(scale: maskScale)]
            )
        else {
            return nil
        }
        return DanmakuHighLikeIcon(
            mask: mask,
            size: image.size,
            descentBelowBaseline: image.alignmentRect.minY,
            spacing: CGFloat(fontSize * spacingFontSizeRatio)
        )
    }
}
