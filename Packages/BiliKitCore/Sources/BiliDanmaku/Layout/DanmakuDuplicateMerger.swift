import BiliModels
import Foundation

/// 重复弹幕合并：同一显示位置、归一化后正文相同、在组首出场后 `windowSeconds` 之内的弹幕并成一条，正文末尾带条数。
///
/// 由 `DanmakuLayoutPlanner` 在车道布局前对一个分段调用，输入已过滤、按 (时间, ID) 排好序；纯函数，结果只取决于
/// 输入，所以 seek 与连续播放看到同样的合并。分组不跨分段：分段末尾的组到此为止，下一段的同文弹幕另起一组。
/// 计数是整组条数，在组首出场时就显示；不跨组累计。
enum DanmakuDuplicateMerger {
    /// 从组首起算的合并时长（媒体秒）。
    ///
    /// 与宽度、窗口都无关，组的成员在排车道前就能确定；取顶部、底部弹幕的显示时长，也接近窄窗口里滚动弹幕的
    /// 可见时长。调长并得更多，但宽窗口里组首还没飞完、同文弹幕被并掉的时间也更长；调短则刷屏时并得少。
    static let windowSeconds = DanmakuMotionPolicy.fixedSeconds
    /// 合并后正文与条数之间的分隔；条数用 ASCII 数字，不随界面语言变化。
    static let countSeparator = " ×"
    /// 合并弹幕 ID 的后缀分隔。
    ///
    /// 合并弹幕的 ID 由组首 ID 与条数组成，与组首不同：纹理与在屏 layer 按 ID 复用，开关合并或条数变化时正文
    /// 不同，必须换一个 ID 重新准备纹理，否则旧纹理会被拉伸到新宽度。
    static let mergedIDSeparator = "#×"
    /// 同一字符连续出现超过这么多次时折叠到这个次数再比较：“哈哈哈哈哈”与“哈哈哈”、“2333333”与“2333”算同一条。
    ///
    /// 调小会把“哈哈”与“哈哈哈”也并到一起，调大则长短不同的刷屏不再合并。
    static let maximumComparedRepetition = 3

    /// 合并后的弹幕，顺序仍按 (时间, ID)；没有同文的弹幕原样保留。
    ///
    /// `events` 必须已按 `DanmakuEvent.precedes` 排序；合并弹幕取组首的时间、位置、颜色与字号，组里任何一条是
    /// 高赞则带高赞标记。
    static func merged(_ events: [DanmakuEvent]) -> [DanmakuEvent] {
        struct GroupKey: Hashable {
            let mode: DanmakuPresentationMode
            let text: String
        }
        struct Group {
            let first: DanmakuEvent
            var count = 1
            var isHighLike: Bool
        }
        var groups: [Group] = []
        var openGroupIndex: [GroupKey: Int] = [:]
        for event in events {
            let key = GroupKey(mode: event.mode, text: comparisonKey(for: event.text))
            if let index = openGroupIndex[key],
                event.timeSeconds - groups[index].first.timeSeconds <= windowSeconds
            {
                groups[index].count += 1
                groups[index].isHighLike = groups[index].isHighLike || event.isHighLike
                continue
            }
            openGroupIndex[key] = groups.count
            groups.append(Group(first: event, isHighLike: event.isHighLike))
        }
        return groups.map { group in
            guard group.count > 1 else { return group.first }
            let first = group.first
            return DanmakuEvent(
                id: first.id + mergedIDSeparator + String(group.count),
                timeSeconds: first.timeSeconds,
                mode: first.mode,
                text: first.text + countSeparator + String(group.count),
                fontSize: first.fontSize,
                colorRGB: first.colorRGB,
                colorStyle: first.colorStyle,
                weight: first.weight,
                isHighLike: group.isHighLike
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
