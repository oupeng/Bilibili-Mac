import BiliApplication
import BiliModels
import Foundation

/// 合并后的一条弹幕：组首，以及并入它的同文弹幕的到达时间。
struct DanmakuDuplicateGroup: Sendable, Equatable {
    /// 组首；组里任何一条是高赞时带高赞标记，其余字段都是组首自己的。
    let event: DanmakuEvent
    /// 组内第 2、3…条的媒体时间，升序；没有同文弹幕时为空。
    let laterArrivalTimes: [Double]
}

/// 重复弹幕合并：同一显示位置、归一化后正文相同、在组首的合并时长之内到达的弹幕并成组首一条。
///
/// 由 `DanmakuLayoutPlanner` 在车道布局前对一个分段调用，输入已过滤、按 (时间, ID) 排好序；纯函数，结果只取决于
/// 输入，所以 seek 与连续播放看到同样的合并。分组不跨分段：分段末尾的组到此为止，下一段的同文弹幕另起一组。
/// 不跨组累计：合并时长之后的同文弹幕另起一组。条数怎样显示由 `DanmakuCountBadge` 决定，组首的正文不变。
enum DanmakuDuplicateMerger {
    /// 滚动组首的合并时长按这个宽度（point）的播放区换算：组首在这么宽的窗口里从右边缘进场到尾缘离开左边界。
    ///
    /// 合并时长不能取真实窗口宽度，否则改窗口尺寸就要重排（见 docs/ARCHITECTURE.md「弹幕」）。偏长的代价重：组首
    /// 已离开窗口还在吞同文弹幕，这句话在用户眼前消失、条数涨在看不见的地方；偏短的代价轻：组首还在屏上时同文的
    /// 下一组又飘出来。取常见播放区里偏窄的宽度：播放区不窄于它时组首在整个合并时长内都看得见，更宽时后段同文会
    /// 再出一条。调大并得更充分但更窄的窗口会偏长，调小则正常窗口里重复更多。
    static let referenceViewportWidth = 640.0
    /// 同一字符连续出现超过这么多次时折叠到这个次数再比较：“哈哈哈哈哈”与“哈哈哈”、“2333333”与“2333”算同一条。
    ///
    /// 调小会把“哈哈”与“哈哈哈”也并到一起，调大则长短不同的刷屏不再合并。
    static let maximumComparedRepetition = 3
    /// 组首本身不是高赞、靠并入的弹幕带上高赞图标时，ID 加这个后缀。
    ///
    /// 纹理与在屏 layer 按 ID 复用，开关合并时同一 ID 若从无图标变成有图标，旧纹理会被拉伸到新宽度；换一个 ID
    /// 就会重新准备纹理。正文不变的合并弹幕沿用组首 ID，开关合并时原位换上新的 placement。
    static let promotedHighLikeIDSuffix = "#highLike"

    /// 组首 `event` 的合并时长（媒体秒）：顶部、底部弹幕是显示时长；滚动弹幕是在 `referenceViewportWidth` 宽的
    /// 播放区里的可见时长，按正文宽与速度档算，不含计数胶囊。
    ///
    /// 加上胶囊后整条更宽，规划画布窄于约 3200pt 时可见得更久，所以不含胶囊算出的时长不会超过实际可见时长，也
    /// 避开了“宽度取决于条数、条数又取决于时长”的循环。
    static func windowSeconds(
        for event: DanmakuEvent,
        textWidth: Double,
        planningWidth: Double,
        speedLevel: DanmakuSpeedLevel
    ) -> Double {
        let duration = DanmakuMotionPolicy.duration(
            for: event.mode,
            textWidth: textWidth,
            planningWidth: planningWidth,
            speedLevel: speedLevel
        )
        guard event.mode == .scrolling else { return duration }
        return DanmakuMotionPolicy.scrollingVisibleSeconds(
            textWidth: textWidth,
            planningWidth: planningWidth,
            durationSeconds: duration,
            viewportWidth: referenceViewportWidth
        )
    }

    /// 合并后的组，顺序仍按组首的 (时间, ID)；没有同文的弹幕自成一组。
    ///
    /// `events` 必须已按 `DanmakuEvent.precedes` 排序。`windowSeconds` 给出一条弹幕作组首时的合并时长；为 nil（无法
    /// 测量、不会显示）时它不开组，也不吸收后来者。
    static func merged(
        _ events: [DanmakuEvent],
        windowSeconds: (DanmakuEvent) -> Double?
    ) -> [DanmakuDuplicateGroup] {
        struct GroupKey: Hashable {
            let mode: DanmakuPresentationMode
            let text: String
        }
        struct Group {
            let first: DanmakuEvent
            let windowSeconds: Double?
            var laterArrivalTimes: [Double] = []
            var isHighLike: Bool
        }
        var groups: [Group] = []
        var openGroupIndex: [GroupKey: Int] = [:]
        for event in events {
            let key = GroupKey(mode: event.mode, text: comparisonKey(for: event.text))
            if let index = openGroupIndex[key],
                let window = groups[index].windowSeconds,
                event.timeSeconds - groups[index].first.timeSeconds <= window
            {
                groups[index].laterArrivalTimes.append(event.timeSeconds)
                groups[index].isHighLike = groups[index].isHighLike || event.isHighLike
                continue
            }
            openGroupIndex[key] = groups.count
            groups.append(
                Group(
                    first: event,
                    windowSeconds: windowSeconds(event),
                    isHighLike: event.isHighLike
                )
            )
        }
        return groups.map { group in
            let first = group.first
            guard group.isHighLike != first.isHighLike else {
                return DanmakuDuplicateGroup(
                    event: first,
                    laterArrivalTimes: group.laterArrivalTimes
                )
            }
            return DanmakuDuplicateGroup(
                event: DanmakuEvent(
                    id: first.id + promotedHighLikeIDSuffix,
                    timeSeconds: first.timeSeconds,
                    mode: first.mode,
                    text: first.text,
                    fontSize: first.fontSize,
                    colorRGB: first.colorRGB,
                    colorStyle: first.colorStyle,
                    weight: first.weight,
                    isHighLike: group.isHighLike
                ),
                laterArrivalTimes: group.laterArrivalTimes
            )
        }
    }

    /// 判断两条弹幕是否同文时比较的形式；只用于比较，显示的始终是原文。
    ///
    /// 依次：全角 ASCII 与全角空格转半角（不动片假名等其他全角字符），拉丁字母转小写，去掉空白，去掉句尾标点与
    /// 波浪号，同一字符连续超过 `maximumComparedRepetition` 次时折叠。全是标点的弹幕不去句尾标点，否则“？？？”
    /// 与“！！！”都会变成空串而互相合并。按 `Character` 处理，组合 emoji 不会被拆开。
    static func comparisonKey(for text: String) -> String {
        let folded = String(String.UnicodeScalarView(text.unicodeScalars.map(halfwidthScalar)))
            .lowercased()
            .filter { !$0.isWhitespace }
        var trimmed = Substring(folded)
        while let last = trimmed.last, isTrailingPunctuation(last) {
            trimmed.removeLast()
        }
        let body = trimmed.isEmpty ? Substring(folded) : trimmed
        var result = ""
        var previous: Character?
        var run = 0
        for character in body {
            run = character == previous ? run + 1 : 1
            previous = character
            if run <= maximumComparedRepetition {
                result.append(character)
            }
        }
        return result
    }

    /// 全角 ASCII（U+FF01–U+FF5E）对应到半角，全角空格对应到半角空格；其余原样。
    private static func halfwidthScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0xFF01...0xFF5E:
            Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
        case 0x3000:
            " "
        default:
            scalar
        }
    }

    private static func isTrailingPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character == "~"
    }
}
