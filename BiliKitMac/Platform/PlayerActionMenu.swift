import AppKit
import BiliApplication
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 播放器动作菜单的意图：加入稍后再看、取当前视频的网页地址与 BV 号、暂停播放。
///
/// 由 `WindowAdapters` 的播放器内容用视频模型、播放引擎的时间线与暂停、窗口的写入入口构造（`make`），交给
/// `PlayerActionMenuController`。门槛与写入在窗口的写入协调者里，这里只决定当下能不能做、给什么提示。不持有状态。
struct PlayerActionMenuActions {
    /// 菜单打开时据此决定「添加到稍后再看」是否可用。
    let canAddToWatchLater: @MainActor () -> Bool
    let addToWatchLater: @MainActor () -> PlayerActionFeedback?
    /// 当前视频带分 P 与时间的网页地址；没有可操作的视频时为 nil（见 `VideoViewModel.shareURL`）。
    let shareURL: @MainActor () -> URL?
    /// 当前视频的 BV 号；没有可操作的视频时为 nil。
    let bvid: @MainActor () -> String?
    let pausePlayback: @MainActor () -> Void

    @MainActor
    static func make(
        videoModel: VideoViewModel,
        timeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        pausePlayback: @escaping @MainActor () -> Void,
        window: PlayerWindowContext
    ) -> Self {
        /// 旧详情此刻不可操作（换视频加载中或失败）时没有视频可操作，免得对已经不是用户想看的那个视频动作。
        func bvid() -> String? {
            videoModel.blocksPresentedContext ? nil : videoModel.presentedBVID
        }
        return Self(
            canAddToWatchLater: { window.canWriteAccount() && bvid() != nil },
            addToWatchLater: {
                guard window.canWriteAccount() else { return .signInRequired }
                guard let bvid = bvid() else { return .unavailable }
                window.addToWatchLater(bvid)
                return .watchLaterRequested
            },
            shareURL: { videoModel.shareURL(timeline: timeline()) },
            bvid: bvid,
            pausePlayback: pausePlayback
        )
    }
}

/// 动作菜单操作后在播放器顶部的提示。
///
/// 全屏（AVKit 独立全屏窗口）下窗口底部的写入结果胶囊看不到，所以操作当下在播放器上给一句；稍后再看的写入结果
/// 仍由胶囊说明，与点赞快捷键相同。
enum PlayerActionFeedback: Equatable {
    case watchLaterRequested
    case signInRequired
    case unavailable
    case linkCopied
    case bvidCopied

    var label: String {
        switch self {
        case .watchLaterRequested: AppStrings.localized("正在添加到稍后再看")
        case .signInRequired: AppStrings.localized("登录后可添加到稍后再看")
        case .unavailable: AppStrings.localized("暂时无法添加到稍后再看")
        case .linkCopied: AppStrings.localized("已拷贝链接")
        case .bvidCopied: AppStrings.localized("已拷贝 BV 号")
        }
    }

    var symbolName: String {
        switch self {
        case .watchLaterRequested: "clock"
        case .signInRequired: "person.crop.circle"
        case .unavailable: "exclamationmark.circle"
        case .linkCopied: "link"
        case .bvidCopied: "doc.on.doc"
        }
    }
}

/// AVKit 控制条动作菜单（`AVPlayerView.actionPopUpButtonMenu`）的内容与执行。
///
/// 用 AppKit：菜单由 AVKit 的原生控制条弹出，只接受 `NSMenu`。窗口下在控制条的动作菜单按钮里；全屏下 AVKit 把它收进
/// 浮动控制条的「»」→「其他」子菜单。由 `NativePlayerHostView` 持有，宿主在创建与每次更新时经 `update` 设置意图与
/// `openURL` 并重建菜单项；窗口下菜单每次打开时（`menuNeedsUpdate`）再按此刻的视频重建一次。全屏时 AVKit 是否对
/// 收进「其他」的菜单调用 `menuNeedsUpdate` 没有保证，所以菜单项不能只在那里建出来，可用状态可能停在上次重建时；
/// 执行时再核对一次，菜单打开期间换了视频也不会对旧视频动作。打开网页只经 SwiftUI 的 `OpenURLAction`，地址只由合法 BVID 拼出，见 SECURITY-MODEL §4。
/// 不持有 Task。
@MainActor
final class PlayerActionMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private var actions: PlayerActionMenuActions?
    private var openURL: OpenURLAction?
    /// 操作后的播放器提示；宿主接到播放器浮层。
    var presentFeedback: (PlayerActionFeedback) -> Void = { _ in }

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    /// 换上新的意图与打开网页的入口并重建菜单项；为 nil 时各项禁用。
    func update(actions: PlayerActionMenuActions?, openURL: OpenURLAction) {
        self.actions = actions
        self.openURL = openURL
        rebuildItems()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildItems()
    }

    private func rebuildItems() {
        menu.removeAllItems()
        let hasVideo = actions?.bvid() != nil
        menu.addItem(
            item(
                VideoCardMenuText.addToWatchLater,
                symbol: "clock",
                isEnabled: actions?.canAddToWatchLater() == true,
                action: #selector(addToWatchLater)
            )
        )
        menu.addItem(.separator())
        for (title, symbol, action) in [
            (VideoCardMenuText.copyLink, "link", #selector(copyLink)),
            (AppStrings.localized("拷贝 BV 号"), "doc.on.doc", #selector(copyBVID)),
            (VideoCardMenuText.openInBrowser, "globe", #selector(openInBrowser))
        ] {
            menu.addItem(item(title, symbol: symbol, isEnabled: hasVideo, action: action))
        }
    }

    private func item(
        _ title: String,
        symbol: String,
        isEnabled: Bool,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = isEnabled
        return item
    }

    @objc private func addToWatchLater() {
        guard let feedback = actions?.addToWatchLater() else { return }
        presentFeedback(feedback)
    }

    @objc private func copyLink() {
        guard let url = actions?.shareURL() else { return }
        VideoLinkPasteboard.copy(url)
        presentFeedback(.linkCopied)
    }

    @objc private func copyBVID() {
        guard let bvid = actions?.bvid() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bvid, forType: .string)
        presentFeedback(.bvidCopied)
    }

    /// 带当前时间打开网页，先暂停应用内播放：网页会自动播放，两边同时出声。
    @objc private func openInBrowser() {
        guard let actions, let openURL, let url = actions.shareURL() else { return }
        actions.pausePlayback()
        openURL(url)
    }
}
