import AppKit
import BiliModels
import CoreText

/// 合并弹幕右侧的计数胶囊：组内后续弹幕的到达时间，以及按最终条数预留的宽度。
///
/// 由 `DanmakuLayoutPlanner` 按 `DanmakuDuplicateMerger` 的分组构造，随车道请求交给 renderer。条数是媒体时间的
/// 纯函数（`count(at:)`）：renderer 把每次变化交给 Core Animation 按媒体时间切换，不随对齐步长刷新，所以暂停、seek
/// 与倍速时看到的都与连续播放一致。组首单独一条时没有胶囊。
public struct DanmakuCountBadge: Sendable, Equatable {
    /// 组内第 2、3…条的媒体时间，升序；第 k 个到达时条数变为 k + 2。
    let laterArrivalTimes: [Double]
    /// 胶囊按哪一档字号排版，与正文纹理的归一化字号相同。
    let fontSize: Double
    /// 正文纹理右缘到胶囊右缘的宽度（point）：间距加最终条数的胶囊宽。
    ///
    /// 车道请求按正文宽加上它申请，所以条数增长时胶囊只在预留的空间里变宽，不会与同车道后面的弹幕重叠。
    let reservedWidth: Double

    /// 没有同文弹幕（`laterArrivalTimes` 为空）时为 nil。
    init?(laterArrivalTimes: [Double], fontSize: Double) {
        guard !laterArrivalTimes.isEmpty else { return nil }
        let fontSize = DanmakuEvent.normalizedFontSize(fontSize)
        let geometry = DanmakuCountBadgeGeometry.geometry(forFontSize: fontSize)
        self.laterArrivalTimes = laterArrivalTimes
        self.fontSize = fontSize
        reservedWidth =
            Double(geometry.spacing + geometry.width(forCount: laterArrivalTimes.count + 1))
    }

    var finalCount: Int { laterArrivalTimes.count + 1 }

    /// `mediaTime` 时的条数：组首算 1，之后每到一条加 1。
    func count(at mediaTime: Double) -> Int {
        1 + laterArrivalTimes.prefix { $0 <= mediaTime }.count
    }
}

/// 计数胶囊的几何与外观，测量（车道预留宽度）与绘制（renderer 的胶囊层）共用这一份。
///
/// 每档字号一份，进程内首次使用时生成、之后只读，任意线程可读。数字用等宽数字字体，每一位宽度相同，条数变化时
/// 只有位数变化才改变胶囊宽度。
struct DanmakuCountBadgeGeometry: Sendable {
    /// 胶囊高度占字号的比例；比正文的字高略矮，胶囊不会撑高弹幕。
    static let heightFontSizeRatio = 0.78
    /// 胶囊里文字的字号占弹幕字号的比例。
    static let glyphFontSizeRatio = 0.62
    /// 胶囊左右内边距占胶囊高度的比例。
    static let horizontalPaddingHeightRatio = 0.35
    /// 正文纹理右缘到胶囊左缘的间距占字号的比例；纹理本身已有描边与阴影的留白，这里只补一点。
    static let spacingFontSizeRatio = 0.08
    /// 胶囊底色：半透明黑，与视频卡片时长角标同一种做法，任何画面上白字都清楚，也不与弹幕颜色冲突。
    static let backgroundOpacity = 0.55
    static let glyphWeight = NSFont.Weight.bold
    /// 条数前的乘号；数字是 ASCII，不随界面语言变化。
    static let timesSign: Character = "×"

    let glyphFontSize: CGFloat
    let height: CGFloat
    let horizontalPadding: CGFloat
    let spacing: CGFloat
    let timesSignWidth: CGFloat
    let digitWidth: CGFloat

    /// 对应字号的几何；字号须已经过 `DanmakuEvent.normalizedFontSize`。
    static func geometry(forFontSize fontSize: Double) -> DanmakuCountBadgeGeometry {
        geometryByFontSize[fontSize] ?? make(fontSize: DanmakuEvent.standardFontSize)
    }

    /// 胶囊里“×”与数字的字体。
    var glyphFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: glyphFontSize, weight: Self.glyphWeight)
    }

    /// 显示 `count` 时胶囊的宽度（point）。
    func width(forCount count: Int) -> CGFloat {
        horizontalPadding * 2 + timesSignWidth + digitWidth * CGFloat(String(count).count)
    }

    private static let geometryByFontSize: [Double: DanmakuCountBadgeGeometry] = Dictionary(
        uniqueKeysWithValues: DanmakuEvent.supportedFontSizes.map { ($0, make(fontSize: $0)) }
    )

    private static func make(fontSize: Double) -> DanmakuCountBadgeGeometry {
        let glyphFontSize = CGFloat(fontSize * glyphFontSizeRatio)
        let glyphFont = NSFont.monospacedDigitSystemFont(ofSize: glyphFontSize, weight: glyphWeight)
        let height = CGFloat(fontSize * heightFontSizeRatio)
        return DanmakuCountBadgeGeometry(
            glyphFontSize: glyphFontSize,
            height: height,
            horizontalPadding: height * CGFloat(horizontalPaddingHeightRatio),
            spacing: CGFloat(fontSize * spacingFontSizeRatio),
            timesSignWidth: advance(of: String(timesSign), font: glyphFont),
            digitWidth: advance(of: "0", font: glyphFont)
        )
    }

    private static func advance(of text: String, font: NSFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font])
        )
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }
}
