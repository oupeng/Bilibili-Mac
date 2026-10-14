import Foundation
import Observation

enum AppTab: Hashable, CaseIterable {
    case search
    case home
    case popular
    case history
}

struct PlaybackDestination: Hashable {
    let surfaceID: UUID
}

struct PlaybackSelectionIntent: Hashable {
    let bvid: String
    /// 应用内显式选中的分 P。
    let preferredCID: Int64?
    /// 外部链接（评论正文）给出的分 P 序号，从 1 开始；超出范围时按默认分 P 打开。
    let preferredPageNumber: Int?
    /// 外部链接给出的起播秒数（`t=`）；超出分 P 时长时忽略。
    let preferredStartSeconds: Int?

    init(
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil,
        preferredStartSeconds: Int? = nil
    ) {
        self.bvid = bvid
        self.preferredCID = preferredCID
        self.preferredPageNumber = preferredPageNumber
        self.preferredStartSeconds = preferredStartSeconds
    }
}

private struct ActivePlayback: Equatable {
    let destination: PlaybackDestination
    var intent: PlaybackSelectionIntent
}

@MainActor
@Observable
/// 协调窗口内的顶层 Tab、原生导航路径与播放生命周期副作用。
///
/// Coordinator 不拥有播放器；typed path 只表达是否位于播放层级，当前 BVID 则表达该
/// 层级内的媒体 identity。系统返回、切换来源与关窗都通过同一条播放副作用边界收口。
final class AppNavigationCoordinator {
    var selectedTab: AppTab = .home {
        didSet {
            guard selectedTab != oldValue else { return }
            closePlayback()
        }
    }
    var playbackPath: [PlaybackDestination] {
        get {
            activePlayback.map { [$0.destination] } ?? []
        }
        set {
            // 只有 openPlayback 可以建立播放 surface；系统 path 写回只负责 pop。
            guard newValue.isEmpty else { return }
            closePlayback()
        }
    }
    var currentPlaybackBVID: String? {
        activePlayback?.intent.bvid
    }
    var currentPlaybackIntent: PlaybackSelectionIntent? {
        activePlayback?.intent
    }
    var searchDraft = ""

    private var activePlayback: ActivePlayback?
    @ObservationIgnored private let startPlayback: (PlaybackSelectionIntent) -> Void
    @ObservationIgnored private let stopPlayback: () -> Void
    @ObservationIgnored private let closeSidebarContext: () -> Void

    /// - Parameters:
    ///   - startPlayback: 开始或替换当前视频。
    ///   - stopPlayback: 关闭播放后停止播放器与弹幕。
    ///   - closeSidebarContext: 关闭压在侧栏上的上下文层（UP 主空间）。上下文层只在播放时存在，
    ///     关闭播放、或从上下文层以外的入口换视频时都会调用。
    init(
        startPlayback: @escaping (PlaybackSelectionIntent) -> Void,
        stopPlayback: @escaping () -> Void,
        closeSidebarContext: @escaping () -> Void = {}
    ) {
        self.startPlayback = startPlayback
        self.stopPlayback = stopPlayback
        self.closeSidebarContext = closeSidebarContext
    }

    /// 首次打开建立播放 surface；连续打开其他视频只替换媒体 identity。
    func openPlayback(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid))
    }

    /// 从侧栏上下文层（UP 主空间）里选择视频：用户仍在逛这个空间，上下文层保留。
    func openPlaybackFromSidebarContext(_ bvid: String) {
        openPlayback(PlaybackSelectionIntent(bvid: bvid), preservesSidebarContext: true)
    }

    /// 来源页、相关推荐、选集、评论链接等入口换视频：用户已离开上下文层，关闭它退回详情。
    ///
    /// 按“从哪里打开”判断，不比较新视频的 UP 主：联合投稿的 UP 主字段可能是另一位。
    /// 重新点击正在播放的视频同样算离开上下文层。
    func openPlayback(_ intent: PlaybackSelectionIntent) {
        openPlayback(intent, preservesSidebarContext: false)
    }

    private func openPlayback(
        _ intent: PlaybackSelectionIntent,
        preservesSidebarContext: Bool
    ) {
        guard !intent.bvid.isEmpty else { return }
        if !preservesSidebarContext {
            closeSidebarContext()
        }
        guard currentPlaybackIntent != intent else { return }

        if var activePlayback {
            activePlayback.intent = intent
            self.activePlayback = activePlayback
        } else {
            activePlayback = ActivePlayback(
                destination: PlaybackDestination(surfaceID: UUID()),
                intent: intent
            )
        }
        startPlayback(intent)
    }

    func retryPlayback() {
        guard let intent = currentPlaybackIntent else { return }
        startPlayback(intent)
    }

    /// 登出只关闭当前播放，不改变来源 Tab 或尚未提交的搜索草稿。
    func closePlaybackForAuthenticationChange() {
        closePlayback()
    }

    /// 关闭当前播放，并恢复一个新窗口应有的来源与搜索草稿。
    func resetForWindowClosure() {
        closePlayback()
        selectedTab = .home
        searchDraft = ""
    }

    private func closePlayback() {
        guard activePlayback != nil else { return }
        activePlayback = nil
        closeSidebarContext()
        stopPlayback()
    }
}
