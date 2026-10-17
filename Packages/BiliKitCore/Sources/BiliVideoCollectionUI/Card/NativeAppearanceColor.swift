import AppKit

extension NSColor {
    /// 按给定外观解析出的 CGColor。
    ///
    /// `cgColor` 按“当前绘制外观”取值并就此定格；在事件回调或外观变化通知里，当前绘制外观未必是
    /// 视图自己的外观。写进 layer 的动态颜色都经由这里解析，并在外观变化时重新写入。
    public func cgColor(for appearance: NSAppearance) -> CGColor {
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = cgColor
        }
        return resolved ?? cgColor
    }
}
