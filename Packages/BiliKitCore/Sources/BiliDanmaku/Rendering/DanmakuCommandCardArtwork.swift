import AppKit
import BiliModels
import CoreText

/// 把一张互动弹幕卡片（评分、投票）画成一张图：半透明黑底圆角、白字，强调色是 B 站粉。
///
/// 由 `DanmakuCommandCardLayers` 在主线程调用；一个视频只有几张卡片，画一次即可。卡片固定尺寸，不随播放区缩放，
/// 与弹幕字号一致。图标都是 SF Symbol，不读接口给出的远端图片。
enum DanmakuCommandCardArtwork {
    /// 卡片宽度（point）。
    static let cardWidth: CGFloat = 200
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 12
    /// 底色：半透明黑，与计数胶囊、UP 主弹幕同一做法，任何画面上白字都清楚。
    static let backgroundOpacity = 0.6
    static let secondaryTextOpacity = 0.7
    /// 强调色：B 站粉，与 UP 主标签一致。
    static let accentRGB = DanmakuUploaderStyle.tagRGB
    static let headerFontSize: CGFloat = 11
    static let titleFontSize: CGFloat = 13
    static let footerFontSize: CGFloat = 11
    static let scoreFontSize: CGFloat = 22
    static let starSize: CGFloat = 9
    static let starSpacing: CGFloat = 3
    /// 评分卡的星数；平均分按满分 `maximumScore` 换算成星数，四舍五入到整颗。
    static let starCount = 5
    static let maximumScore = 10.0
    static let voteRowHeight: CGFloat = 18
    static let voteRowSpacing: CGFloat = 4
    static let voteBarOpacity = 0.55
    static let lineSpacing: CGFloat = 6

    struct Artwork {
        let image: CGImage
        let size: CGSize
    }

    static func artwork(for card: DanmakuCommandCard, scale: CGFloat) -> Artwork? {
        switch card.content {
        case .grade(let grade):
            render(
                size: CGSize(
                    width: cardWidth,
                    height: padding * 2 + headerFontSize + lineSpacing + titleFontSize + lineSpacing
                        + starSize + lineSpacing + footerFontSize
                ),
                scale: scale
            ) { context, size in
                drawGrade(grade, in: context, size: size)
            }
        case .vote(let vote):
            render(
                size: CGSize(
                    width: cardWidth,
                    height: padding * 2 + headerFontSize + lineSpacing + titleFontSize + lineSpacing
                        + CGFloat(vote.options.count) * (voteRowHeight + voteRowSpacing)
                        + footerFontSize
                ),
                scale: scale
            ) { context, size in
                drawVote(vote, in: context, size: size)
            }
        }
    }

    /// 评分卡四行：类型、标题、星星、说明；平均分大字靠右，与标题、星星两行并排。
    private static func drawGrade(_ grade: DanmakuGradeCard, in context: CGContext, size: CGSize) {
        let top = drawHeader(
            "star.fill",
            DanmakuStrings.localized("评分"),
            in: context,
            top: size.height - padding
        )
        let starsBaseline = padding + footerFontSize + lineSpacing
        let score = line(
            String(format: "%.1f", grade.averageScore),
            font(scoreFontSize, .bold),
            NSColor.white
        )
        let scoreWidth = width(score)
        context.textPosition = CGPoint(x: size.width - padding - scoreWidth, y: starsBaseline)
        CTLineDraw(score, context)
        _ = drawTitle(
            grade.title,
            in: context,
            top: top,
            maxWidth: size.width - padding * 3 - scoreWidth
        )
        // 登录且打过分时，星星与说明换成自己的评分；否则星星是平均分换算的星数，说明是参与人数。
        let filled =
            grade.myScore ?? Int((grade.averageScore / maximumScore * Double(starCount)).rounded())
        var x = padding
        for index in 0..<starCount {
            let starWidth = symbol(
                index < filled ? "star.fill" : "star",
                size: starSize,
                color: accent,
                in: context,
                at: CGPoint(x: x, y: starsBaseline)
            )
            x += starWidth + starSpacing
        }
        let footerText =
            grade.myScore.map { DanmakuStrings.localized("已评 \($0) 星") }
            ?? DanmakuStrings.localized("\(grade.participantCount) 人参与")
        let footer = truncated(
            footerText,
            font(footerFontSize),
            NSColor.white.withAlphaComponent(secondaryTextOpacity),
            maxWidth: size.width - padding * 2
        )
        context.textPosition = CGPoint(x: padding, y: padding)
        CTLineDraw(footer, context)
    }

    private static func drawVote(_ vote: DanmakuVoteCard, in context: CGContext, size: CGSize) {
        var top = size.height - padding
        top = drawHeader("chart.bar.fill", DanmakuStrings.localized("投票"), in: context, top: top)
        top = drawTitle(vote.question, in: context, top: top, maxWidth: size.width - padding * 2)
        let total = max(vote.options.reduce(0) { $0 + $1.voteCount }, 1)
        for (index, option) in vote.options.enumerated() {
            let isMine = index == vote.myOptionIndex
            let bar = CGRect(
                x: padding,
                y: top - voteRowHeight,
                width: size.width - padding * 2,
                height: voteRowHeight
            )
            fill(bar, radius: 4, color: NSColor.white.withAlphaComponent(0.12), in: context)
            let fraction = CGFloat(option.voteCount) / CGFloat(total)
            fill(
                CGRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height),
                radius: 4,
                color: accent.withAlphaComponent(isMine ? 1 : voteBarOpacity),
                in: context
            )
            let percent = line(
                "\(Int((fraction * 100).rounded()))%",
                font(footerFontSize, .semibold),
                NSColor.white
            )
            let percentWidth = width(percent)
            var textX = bar.minX + 6
            if isMine {
                let checkWidth = symbol(
                    "checkmark",
                    size: starSize,
                    color: .white,
                    in: context,
                    at: CGPoint(x: textX, y: bar.minY + 5)
                )
                textX += checkWidth + 4
            }
            let text = truncated(
                option.text,
                font(footerFontSize, isMine ? .semibold : .regular),
                NSColor.white,
                maxWidth: bar.maxX - percentWidth - 12 - textX
            )
            context.textPosition = CGPoint(x: textX, y: bar.minY + 5)
            CTLineDraw(text, context)
            context.textPosition = CGPoint(x: bar.maxX - 6 - percentWidth, y: bar.minY + 5)
            CTLineDraw(percent, context)
            top -= voteRowHeight + voteRowSpacing
        }
        let footer = line(
            DanmakuStrings.localized("\(vote.participantCount) 人参与"),
            font(footerFontSize),
            NSColor.white.withAlphaComponent(secondaryTextOpacity)
        )
        context.textPosition = CGPoint(x: padding, y: padding)
        CTLineDraw(footer, context)
    }

    /// 左上角的图标与类型名，返回下一行的上沿。
    private static func drawHeader(
        _ symbolName: String,
        _ title: String,
        in context: CGContext,
        top: CGFloat
    ) -> CGFloat {
        let baseline = top - headerFontSize
        let iconWidth = symbol(
            symbolName,
            size: headerFontSize,
            color: accent,
            in: context,
            at: CGPoint(x: padding, y: baseline - 1)
        )
        let header = line(title, font(headerFontSize, .semibold), accent)
        context.textPosition = CGPoint(x: padding + iconWidth + 4, y: baseline)
        CTLineDraw(header, context)
        return baseline - lineSpacing
    }

    /// 一行标题（评分标题或投票问题），超长时截断，返回下一行的上沿。
    private static func drawTitle(
        _ title: String,
        in context: CGContext,
        top: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        let baseline = top - titleFontSize
        let text = truncated(
            title,
            font(titleFontSize, .semibold),
            NSColor.white,
            maxWidth: maxWidth
        )
        context.textPosition = CGPoint(x: padding, y: baseline)
        CTLineDraw(text, context)
        return baseline - lineSpacing
    }

    private static func render(
        size: CGSize,
        scale: CGFloat,
        draw: (CGContext, CGSize) -> Void
    ) -> Artwork? {
        guard
            let context = CGContext(
                data: nil,
                width: Int(ceil(size.width * scale)),
                height: Int(ceil(size.height * scale)),
                bitsPerComponent: DanmakuTexturePayload.bitsPerComponent,
                bytesPerRow: 0,
                space: DanmakuTexturePayload.colorSpace,
                bitmapInfo: DanmakuTexturePayload.bitmapInfo.rawValue
            )
        else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        fill(
            CGRect(origin: .zero, size: size),
            radius: cornerRadius,
            color: NSColor.black.withAlphaComponent(backgroundOpacity),
            in: context
        )
        draw(context, size)
        return context.makeImage().map { Artwork(image: $0, size: size) }
    }

    private static var accent: NSColor {
        NSColor(
            srgbRed: CGFloat((accentRGB >> 16) & 0xFF) / 255,
            green: CGFloat((accentRGB >> 8) & 0xFF) / 255,
            blue: CGFloat(accentRGB & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    private static func line(_ text: String, _ font: NSFont, _ color: NSColor) -> CTLine {
        CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: color.cgColor]
            )
        )
    }

    private static func truncated(
        _ text: String,
        _ font: NSFont,
        _ color: NSColor,
        maxWidth: CGFloat
    ) -> CTLine {
        let full = line(text, font, color)
        guard width(full) > maxWidth else { return full }
        let token = line("…", font, color)
        return CTLineCreateTruncatedLine(full, Double(max(maxWidth, 0)), .end, token) ?? full
    }

    private static func width(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func fill(
        _ rect: CGRect,
        radius: CGFloat,
        color: NSColor,
        in context: CGContext
    ) {
        context.addPath(
            CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        )
        context.setFillColor(color.cgColor)
        context.fillPath()
    }

    /// 画一个 SF Symbol，返回它占的宽度（point）；符号不可用时什么都不画，宽度为 0。
    @discardableResult
    private static func symbol(
        _ name: String,
        size: CGFloat,
        color: NSColor,
        in context: CGContext,
        at origin: CGPoint
    ) -> CGFloat {
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .semibold))
        else {
            return 0
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard
            let mask = image.cgImage(
                forProposedRect: &rect,
                context: nil,
                hints: [.ctm: AffineTransform(scale: DanmakuTextureRasterizer.maximumBackingScale)]
            )
        else {
            return 0
        }
        let target = CGRect(origin: origin, size: image.size)
        context.saveGState()
        context.clip(to: target, mask: mask)
        context.setFillColor(color.cgColor)
        context.fill(target)
        context.restoreGState()
        return image.size.width
    }
}
