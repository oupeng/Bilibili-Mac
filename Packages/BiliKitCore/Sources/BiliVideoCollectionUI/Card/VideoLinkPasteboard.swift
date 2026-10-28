import AppKit

/// 把视频的网页地址或 BV 号放进系统剪贴板，先清空原有内容。
///
/// 卡片菜单的「拷贝链接」与 App 的播放器动作菜单（「拷贝链接」「拷贝 BV 号」）共用。
public enum VideoLinkPasteboard {
    /// 同一地址同时写成 URL 与纯文本，粘贴到网址栏与文本框都成立。
    @MainActor
    public static func copy(_ url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .URL)
        item.setString(url.absoluteString, forType: .string)
        write(item)
    }

    /// 只写纯文本，用于 BV 号这类不是地址的内容。
    @MainActor
    public static func copy(text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        write(item)
    }

    @MainActor
    private static func write(_ item: NSPasteboardItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}
