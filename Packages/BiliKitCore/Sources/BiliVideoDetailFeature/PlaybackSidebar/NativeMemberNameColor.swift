import AppKit

/// 用户名的颜色：大会员为粉色；评论作者与播放侧栏 UP 主共用这一规则。
enum NativeMemberNameColor {
    static func color(isVIP: Bool) -> NSColor {
        isVIP ? .systemPink : .labelColor
    }
}
