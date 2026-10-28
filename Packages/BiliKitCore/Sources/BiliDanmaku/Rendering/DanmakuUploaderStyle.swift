import AppKit
import CoreText

/// UP 主弹幕的外观：整条套在半透明黑底圆角里，开头一个粉色“UP主”标签。
///
/// 测量与栅格化共用这一份几何：`lineLayout` 按 `leadingWidth` 与 `trailingWidth` 加宽纹理，文字右移 `leadingWidth`；
/// 纹理高度不变，黑底铺满纹理（四周只留 1 像素），所以 UP 主弹幕与同字号的普通弹幕占同样多的车道。
/// 栅格化时先照常合成文字的描边与阴影，再由 `compose` 把黑底垫在下面、标签盖在最上面，标签不带描边。
struct DanmakuUploaderStyle {
    /// 标签文字字号占弹幕字号的比例，与网页播放器相同。
    static let tagFontSizeRatio = 0.6
    /// 标签左右内边距与上下内边距占弹幕字号的比例。
    static let tagHorizontalPaddingRatio = 0.25
    static let tagVerticalPaddingRatio = 0.08
    /// 标签右缘到正文的间距、黑底左缘到标签与正文右缘到黑底右缘的留白，都占弹幕字号的比例。
    static let tagSpacingRatio = 0.25
    static let backgroundLeadingRatio = 0.3
    static let backgroundTrailingRatio = 0.35
    /// 黑底的不透明度，与网页播放器相同；正文仍按自己的颜色描边，深色正文在黑底上也读得出。
    static let backgroundOpacity = 0.5
    /// 标签底色：B 站粉，与互动弹幕卡片的强调色一致。
    static let tagRGB: UInt32 = 0xFB_7299

    let tagLine: CTLine
    let tagSize: CGSize
    let tagFont: NSFont
    let backgroundLeading: CGFloat
    let tagSpacing: CGFloat
    /// 正文之前要让出的宽度（point）：黑底左留白、标签与标签后的间距。
    let leadingWidth: CGFloat
    /// 正文之后黑底的右留白（point）。
    let trailingWidth: CGFloat

    init(fontSize: Double) {
        let size = CGFloat(fontSize)
        tagFont = NSFont.systemFont(
            ofSize: size * CGFloat(Self.tagFontSizeRatio),
            weight: DanmakuTextureRasterizer.fontWeight
        )
        tagLine = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: DanmakuStrings.localized("UP主"),
                attributes: [.font: tagFont, .foregroundColor: NSColor.white.cgColor]
            )
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(tagLine, nil, nil, nil))
        tagSize = CGSize(
            width: ceil(textWidth + size * CGFloat(Self.tagHorizontalPaddingRatio) * 2),
            height: ceil(
                tagFont.ascender - tagFont.descender
                    + size * CGFloat(Self.tagVerticalPaddingRatio) * 2
            )
        )
        backgroundLeading = size * CGFloat(Self.backgroundLeadingRatio)
        tagSpacing = size * CGFloat(Self.tagSpacingRatio)
        leadingWidth = backgroundLeading + tagSize.width + tagSpacing
        trailingWidth = size * CGFloat(Self.backgroundTrailingRatio)
    }

    /// 在已合成描边与阴影的文字像素下面垫黑底、上面盖标签，返回同尺寸的预乘 RGBA；失败时为 nil。
    ///
    /// `textPixels` 与返回值的像素格式都是 `DanmakuTexturePayload` 的约定；`textLeft` 是正文起点（point，含纹理留白）。
    func compose(
        textPixels: Data,
        layout: DanmakuTextLineLayout,
        scale: CGFloat,
        textLeft: CGFloat
    ) -> Data? {
        guard
            let text = DanmakuTexturePayload(
                pixels: textPixels,
                widthPixels: layout.widthPixels,
                heightPixels: layout.heightPixels,
                bytesPerRow: layout.bytesPerRow,
                backingScale: Double(scale)
            ),
            let buffer = calloc(layout.bytesPerRow * layout.heightPixels, 1)
        else {
            return nil
        }
        guard
            let context = CGContext(
                data: buffer,
                width: layout.widthPixels,
                height: layout.heightPixels,
                bitsPerComponent: DanmakuTexturePayload.bitsPerComponent,
                bytesPerRow: layout.bytesPerRow,
                space: DanmakuTexturePayload.colorSpace,
                bitmapInfo: DanmakuTexturePayload.bitmapInfo.rawValue
            )
        else {
            free(buffer)
            return nil
        }
        let width = CGFloat(layout.widthPixels) / scale
        let height = CGFloat(layout.heightPixels) / scale
        context.scaleBy(x: scale, y: scale)
        let inset = 1 / scale
        let background = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            .insetBy(dx: inset, dy: inset)
        context.addPath(
            CGPath(
                roundedRect: background,
                cornerWidth: background.height / 2,
                cornerHeight: background.height / 2,
                transform: nil
            )
        )
        context.setFillColor(NSColor.black.withAlphaComponent(Self.backgroundOpacity).cgColor)
        context.fillPath()
        context.draw(text.image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let tag = CGRect(
            x: textLeft - tagSpacing - tagSize.width,
            y: (height - tagSize.height) / 2,
            width: tagSize.width,
            height: tagSize.height
        )
        context.addPath(
            CGPath(
                roundedRect: tag,
                cornerWidth: tag.height / 2,
                cornerHeight: tag.height / 2,
                transform: nil
            )
        )
        let rgb = Self.tagRGB
        context.setFillColor(
            CGColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        )
        context.fillPath()
        let textWidth = CGFloat(CTLineGetTypographicBounds(tagLine, nil, nil, nil))
        context.textPosition = CGPoint(
            x: tag.midX - textWidth / 2,
            y: tag.midY - (tagFont.ascender + tagFont.descender) / 2
        )
        CTLineDraw(tagLine, context)
        return Data(
            bytesNoCopy: buffer,
            count: layout.bytesPerRow * layout.heightPixels,
            deallocator: .free
        )
    }
}
