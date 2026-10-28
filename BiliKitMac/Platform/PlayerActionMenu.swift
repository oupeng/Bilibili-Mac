import AppKit
import BiliApplication
import BiliUI
import BiliVideoCollectionUI
import BiliVideoDetailFeature
import SwiftUI

/// 播放器动作菜单的意图：加入稍后再看、取当前视频的网页地址与 BV 号、暂停播放。
///
/// 由 `WindowAdapters` 的播放器内容用视频模型、播放引擎的时间线与暂停、窗口的写入入口构造（`make`），交给
/// `PlayerActionMenuController`。门槛与写入在窗口的写入协调者里，这里只决定当下能不能做、给什么提示；协调者没有发出
/// 写入时不给提示，免得说出没有发生的事。不持有状态。
struct PlayerActionMenuActions {
    /// 刷新可用状态时据此决定「添加到稍后再看」是否可用。
    let canAddToWatchLater: @MainActor () -> Bool
    let addToWatchLater: @MainActor () -> PlayerActionFeedback?
    /// 当前视频带分 P 与时间的网页地址；没有可操作的视频时为 nil（见 `VideoViewModel.shareURL`）。
    let shareURL: @MainActor () -> URL?
    /// 当前可操作视频的 BV 号（`VideoViewModel.operableBVID`）。
    let bvid: @MainActor () -> String?
    let pausePlayback: @MainActor () -> Void

    @MainActor
    static func make(
        videoModel: VideoViewModel,
        timeline: @escaping @MainActor () -> PlaybackTimelineSnapshot,
        pausePlayback: @escaping @MainActor () -> Void,
        window: PlayerWindowContext
    ) -> Self {
        Self(
            canAddToWatchLater: { window.canWriteAccount() && videoModel.operableBVID != nil },
            addToWatchLater: {
                guard window.canWriteAccount() else { return .signInRequired }
                guard let bvid = videoModel.operableBVID else { return .unavailable }
                return window.addToWatchLater(bvid) ? .watchLaterRequested : nil
            },
            shareURL: { videoModel.shareURL(timeline: timeline()) },
            bvid: { videoModel.operableBVID },
            pausePlayback: pausePlayback
        )
    }
}

/// 动作菜单操作后在播放器顶部的提示。
///
/// 全屏（AVKit 独立全屏窗口）下窗口底部的写入结果胶囊看不到，所以操作当下在播放器上给一句；稍后再看的写入结果
/// 仍由胶囊说明，与点赞快捷键相同。`unavailable` 是执行时发现已没有可操作的视频（全屏下菜单的可用状态可能是旧的）。
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
        case .unavailable: AppStrings.localized("暂时无法操作当前视频")
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
/// 浮动控制条的「»」→「其他」子菜单。由 `NativePlayerHostView` 持有；菜单项只在创建时建一次，之后只原地改可用状态，
/// 菜单打开期间宿主更新也不会删掉用户正指着的项。宿主在创建与每次更新时经 `update` 换上意图并刷新可用状态，窗口下菜单
/// 每次打开时（`menuNeedsUpdate`）再刷新一次；全屏时 AVKit 不保证调用它，可用状态可能停在上次刷新时，所以执行时再核对，
/// 已没有可操作的视频就提示，不对旧视频动作。打开网页只经 SwiftUI 的 `OpenURLAction`，地址只由合法 BVID 拼出，
/// 见 SECURITY-MODEL §4。不持有 Task。
@MainActor
final class PlayerActionMenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    /// 宿主第一次 `update` 之前为 nil，各项禁用。
    private var actions: PlayerActionMenuActions?
    private var openURL: OpenURLAction?
    /// 操作后的播放器提示；宿主接到播放器浮层。
    var presentFeedback: (PlayerActionFeedback) -> Void = { _ in }

    private lazy var watchLaterItem = item(
        VideoCardMenuText.addToWatchLater,
        symbol: "clock",
        action: #selector(addToWatchLater)
    )
    private lazy var videoItems = [
        item(VideoCardMenuText.copyLink, symbol: "link", action: #selector(copyLink)),
        item(AppStrings.localized("拷贝 BV 号"), symbol: "doc.on.doc", action: #selector(copyBVID)),
        item(VideoCardMenuText.openInBrowser, symbol: "globe", action: #selector(openInBrowser))
    ]

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(watchLaterItem)
        menu.addItem(.separator())
        videoItems.forEach(menu.addItem)
        refreshItemStates()
    }

    /// 换上新的意图与打开网页的入口，并刷新可用状态。
    func update(actions: PlayerActionMenuActions, openURL: OpenURLAction) {
        self.actions = actions
        self.openURL = openURL
        refreshItemStates()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshItemStates()
    }

    private func refreshItemStates() {
        watchLaterItem.isEnabled = actions?.canAddToWatchLater() == true
        let hasVideo = actions?.bvid() != nil
        for item in videoItems {
            item.isEnabled = hasVideo
        }
    }

    private func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc private func addToWatchLater() {
        guard let feedback = actions?.addToWatchLater() else { return }
        presentFeedback(feedback)
    }

    @objc private func copyLink() {
        guard let url = actions?.shareURL() else { return presentFeedback(.unavailable) }
        VideoLinkPasteboard.copy(url)
        presentFeedback(.linkCopied)
    }

    @objc private func copyBVID() {
        guard let bvid = actions?.bvid() else { return presentFeedback(.unavailable) }
        VideoLinkPasteboard.copy(text: bvid)
        presentFeedback(.bvidCopied)
    }

    /// 带当前时间打开网页，先暂停应用内播放：网页会自动播放，两边同时出声。
    @objc private func openInBrowser() {
        guard let actions, let openURL, let url = actions.shareURL() else {
            return presentFeedback(.unavailable)
        }
        actions.pausePlayback()
        openURL(url)
    }
}
