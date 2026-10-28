import AppKit
import BiliModels
import CoreText

/// 把一张互动弹幕卡片（评分、投票、关联视频）画成一张图：半透明黑底圆角、白字，强调色是 B 站粉。
///
/// 由 `DanmakuCommandCardLayers` 在主线程调用；解码时每个视频最多留 30 张卡片（BiliAPI 的
/// `DanmakuCommandDecoder.maximumCardCount`），每张画一次。卡片固定宽度，不随播放区缩放，与弹幕字号一致。
/// 图标都是 SF Symbol。关联视频的封面不画进这张图：图里只留占位底色，`Artwork.coverFrame` 给出位置，
/// 封面到达后由卡片层放进那里的子层，不必为它重画整张卡。
/// 竖向排版只由 `Rows` 算一次：卡片高度与每行的位置出自同一份行高，改行高不会裁字。
enum DanmakuCommandCardArtwork {
    /// 卡片宽度（point）。
    static let cardWidth: CGFloat = 200
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 12
    /// 底色：半透明黑，与计数胶囊、UP 主弹幕同一做法，任何画面上白字都清楚；比计数胶囊深，卡片字多、字小。
    static let backgroundOpacity = 0.7
    static let secondaryTextOpacity = 0.7
    /// 强调色：B 站粉，与 UP 主标签一致。
    static let accentRGB = DanmakuUploaderStyle.tagRGB
    static let headerFontSize: CGFloat = 11
    static let titleFontSize: CGFloat = 13
    static let footerFontSize: CGFloat = 11
    static let scoreFontSize: CGFloat = 22
    /// 行与行之间的间距。
    static let lineSpacing: CGFloat = 6
    /// 图标与旁边文字的间距。
    static let iconSpacing: CGFloat = 4
    /// 类型图标比文字基线低一点，与小号文字视觉对齐。
    static let headerIconDrop: CGFloat = 1
    static let starSize: CGFloat = 9
    static let starSpacing: CGFloat = 3
    /// 评分卡的星数；平均分按满分 `maximumScore` 换算成星数，四舍五入到整颗。
    static let starCount = 5
    static let maximumScore = 10.0
    static let voteRowHeight: CGFloat = 18
    static let voteRowSpacing: CGFloat = 4
    static let voteBarCornerRadius: CGFloat = 4
    /// 选项横条底轨与占比填充的不透明度；自己投的选项填充不透明。
    static let voteTrackOpacity = 0.12
    static let voteFillOpacity = 0.55
    /// 选项文字离横条左右边与底边的距离。
    static let voteTextHorizontalInset: CGFloat = 6
    static let voteTextBaselineInset: CGFloat = 5
    /// 选项文字与右侧百分比之间至少留出的间距。
    static let votePercentSpacing: CGFloat = 6
    /// 关联视频封面的尺寸（16:9，现在的稿件封面多是这个比例，其他比例填满后裁切）与圆角。
    static let coverSize = CGSize(width: 64, height: 36)
    static let coverCornerRadius: CGFloat = 4
    /// 封面到达前占位底色的不透明度，与投票横条底轨一致。
    static let coverPlaceholderOpacity = voteTrackOpacity
    /// 封面与右侧标题的间距。
    static let coverSpacing: CGFloat = 8
    /// 关联视频标题最多两行，第二行超长时截断。
    static let linkTitleLineCount = 2
    static let linkTitleFontSize: CGFloat = 12

    struct Artwork {
        let image: CGImage
        let size: CGSize
        /// 关联视频封面在卡片里的位置（point，原点在左上角、y 向下，与卡片层的子层坐标一致）；其他卡片为 nil。
        var coverFrame: CGRect?
    }

    static func artwork(for card: DanmakuCommandCard, scale: CGFloat) -> Artwork? {
        switch card.content {
        case .grade(let grade):
            let rows = Rows.grade
            return render(height: rows.cardHeight, scale: scale) { context in
                drawGrade(grade, rows: rows, in: context)
            }
        case .vote(let vote):
            let rows = Rows.vote(optionCount: vote.options.count)
            return render(height: rows.cardHeight, scale: scale) { context in
                drawVote(vote, rows: rows, in: context)
            }
        case .link(let link):
            let rows = Rows.link
            let cover = CGRect(
                origin: CGPoint(x: padding, y: rows.bottom(ofRow: 1)),
                size: coverSize
            )
            var artwork = render(height: rows.cardHeight, scale: scale) { context in
                drawLink(link, rows: rows, cover: cover, in: context)
            }
            // 绘制坐标原点在左下角，子层坐标原点在左上角。
            artwork?.coverFrame = CGRect(
                origin: CGPoint(x: cover.minX, y: rows.cardHeight - cover.maxY),
                size: cover.size
            )
            return artwork
        }
    }

    /// 竖向排版：自上而下每一行的高度与它之后的间距。
    ///
    /// 卡片高度与每行底边的位置都由它算出。
    private struct Rows {
        let heights: [CGFloat]
        let spacingsAfter: [CGFloat]

        /// 评分卡四行：类型、标题、星星、说明。
        static let grade = Rows(
            heights: [headerFontSize, titleFontSize, starSize, footerFontSize],
            spacingsAfter: [lineSpacing, lineSpacing, lineSpacing, 0]
        )

        /// 投票卡：类型、问题、每个选项一行、说明。
        static func vote(optionCount: Int) -> Rows {
            Rows(
                heights: [headerFontSize, titleFontSize]
                    + Array(repeating: voteRowHeight, count: optionCount) + [footerFontSize],
                spacingsAfter: [lineSpacing, lineSpacing]
                    + Array(repeating: voteRowSpacing, count: optionCount) + [0]
            )
        }

        /// 关联视频卡两行：类型、封面与右侧标题。
        static let link = Rows(
            heights: [headerFontSize, coverSize.height],
            spacingsAfter: [lineSpacing, 0]
        )

        var cardHeight: CGFloat {
            padding * 2 + heights.reduce(0, +) + spacingsAfter.reduce(0, +)
        }

        /// 第 `index` 行底边的 y（坐标原点在卡片左下角）；文字以它为基线。
        func bottom(ofRow index: Int) -> CGFloat {
            var y = cardHeight - padding
            for row in 0...index {
                y -= heights[row]
                if row < index { y -= spacingsAfter[row] }
            }
            return y
        }
    }

    private static func drawGrade(_ grade: DanmakuGradeCard, rows: Rows, in context: CGContext) {
        drawHeader(
            "star.fill",
            DanmakuStrings.localized("评分"),
            baseline: rows.bottom(ofRow: 0),
            in: context
        )
        let starsBaseline = rows.bottom(ofRow: 2)
        let score = line(
            String(format: "%.1f", grade.averageScore),
            font(scoreFontSize, .bold),
            NSColor.white
        )
        let scoreWidth = width(score)
        context.textPosition = CGPoint(x: cardWidth - padding - scoreWidth, y: starsBaseline)
        CTLineDraw(score, context)
        drawTitle(
            grade.title,
            baseline: rows.bottom(ofRow: 1),
            maxWidth: cardWidth - padding * 3 - scoreWidth,
            in: context
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
        drawFooter(footerText, baseline: rows.bottom(ofRow: 3), in: context)
    }

    private static func drawVote(_ vote: DanmakuVoteCard, rows: Rows, in context: CGContext) {
        drawHeader(
            "chart.bar.fill",
            DanmakuStrings.localized("投票"),
            baseline: rows.bottom(ofRow: 0),
            in: context
        )
        drawTitle(
            vote.question,
            baseline: rows.bottom(ofRow: 1),
            maxWidth: cardWidth - padding * 2,
            in: context
        )
        // 按浮点相加：票数由解码器限了上限，这里再不让远端数值在整数相加时溢出。
        let total = max(vote.options.reduce(0.0) { $0 + Double($1.voteCount) }, 1)
        for (index, option) in vote.options.enumerated() {
            let isMine = index == vote.myOptionIndex
            let bar = CGRect(
                x: padding,
                y: rows.bottom(ofRow: 2 + index),
                width: cardWidth - padding * 2,
                height: voteRowHeight
            )
            fill(
                bar,
                radius: voteBarCornerRadius,
                color: NSColor.white.withAlphaComponent(voteTrackOpacity),
                in: context
            )
            let fraction = CGFloat(Double(option.voteCount) / total)
            fill(
                CGRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height),
                radius: voteBarCornerRadius,
                color: accent.withAlphaComponent(isMine ? 1 : voteFillOpacity),
                in: context
            )
            let percent = line(
                "\(Int((fraction * 100).rounded()))%",
                font(footerFontSize, .semibold),
                NSColor.white
            )
            let percentWidth = width(percent)
            let baseline = bar.minY + voteTextBaselineInset
            var textX = bar.minX + voteTextHorizontalInset
            if isMine {
                let checkWidth = symbol(
                    "checkmark",
                    size: starSize,
                    color: .white,
                    in: context,
                    at: CGPoint(x: textX, y: baseline)
                )
                textX += checkWidth + iconSpacing
            }
            let percentX = bar.maxX - voteTextHorizontalInset - percentWidth
            let text = truncated(
                option.text,
                font(footerFontSize, isMine ? .semibold : .regular),
                NSColor.white,
                maxWidth: percentX - votePercentSpacing - textX
            )
            context.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(text, context)
            context.textPosition = CGPoint(x: percentX, y: baseline)
            CTLineDraw(percent, context)
        }
        drawFooter(
            DanmakuStrings.localized("\(vote.participantCount) 人参与"),
            baseline: rows.bottom(ofRow: 2 + vote.options.count),
            in: context
        )
    }

    /// 类型、封面占位与封面右侧最多两行的标题，标题与封面顶边对齐。
    private static func drawLink(
        _ link: DanmakuLinkCard,
        rows: Rows,
        cover: CGRect,
        in context: CGContext
    ) {
        drawHeader(
            "play.rectangle.fill",
            DanmakuStrings.localized("关联视频"),
            baseline: rows.bottom(ofRow: 0),
            in: context
        )
        fill(
            cover,
            radius: coverCornerRadius,
            color: NSColor.white.withAlphaComponent(coverPlaceholderOpacity),
            in: context
        )
        let titleFont = font(linkTitleFontSize, .semibold)
        let textX = cover.maxX + coverSpacing
        let lines = wrapped(
            link.title,
            titleFont,
            NSColor.white,
            maxWidth: cardWidth - padding - textX,
            maxLines: linkTitleLineCount
        )
        let lineHeight = titleFont.ascender - titleFont.descender
        var baseline = cover.maxY - titleFont.ascender
        for line in lines {
            context.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(line, context)
            baseline -= lineHeight
        }
    }

    /// 左上角的图标与类型名。
    private static func drawHeader(
        _ symbolName: String,
        _ title: String,
        baseline: CGFloat,
        in context: CGContext
    ) {
        let iconWidth = symbol(
            symbolName,
            size: headerFontSize,
            color: accent,
            in: context,
            at: CGPoint(x: padding, y: baseline - headerIconDrop)
        )
        let header = line(title, font(headerFontSize, .semibold), accent)
        context.textPosition = CGPoint(x: padding + iconWidth + iconSpacing, y: baseline)
        CTLineDraw(header, context)
    }

    /// 一行标题（评分标题或投票问题），超长时截断。
    private static func drawTitle(
        _ title: String,
        baseline: CGFloat,
        maxWidth: CGFloat,
        in context: CGContext
    ) {
        let text = truncated(
            title,
            font(titleFontSize, .semibold),
            NSColor.white,
            maxWidth: maxWidth
        )
        context.textPosition = CGPoint(x: padding, y: baseline)
        CTLineDraw(text, context)
    }

    /// 最后一行的灰色说明，超长时截断。
    private static func drawFooter(_ text: String, baseline: CGFloat, in context: CGContext) {
        let footer = truncated(
            text,
            font(footerFontSize),
            NSColor.white.withAlphaComponent(secondaryTextOpacity),
            maxWidth: cardWidth - padding * 2
        )
        context.textPosition = CGPoint(x: padding, y: baseline)
        CTLineDraw(footer, context)
    }

    private static func render(
        height: CGFloat,
        scale: CGFloat,
        draw: (CGContext) -> Void
    ) -> Artwork? {
        let size = CGSize(width: cardWidth, height: height)
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
        draw(context)
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

    /// 按宽度断行，最多 `maxLines` 行；还有剩余文字时最后一行截断。
    private static func wrapped(
        _ text: String,
        _ font: NSFont,
        _ color: NSColor,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> [CTLine] {
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color.cgColor]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = attributed.length
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < maxLines {
            if lines.count == maxLines - 1 {
                let rest = (text as NSString).substring(from: start)
                lines.append(truncated(rest, font, color, maxWidth: maxWidth))
                break
            }
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(maxWidth, 1)))
            guard count > 0 else { break }
            let range = CFRange(location: start, length: count)
            lines.append(CTTypesetterCreateLine(typesetter, range))
            start += count
        }
        return lines
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
