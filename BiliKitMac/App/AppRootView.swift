//
//  AppRootView.swift
//  BiliKitMac
//
//  Created by shiinayane on 2026/07/21.
//

import BiliApplication
import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import BiliVideoDetailFeature
import Combine
import SwiftUI

/// 窗口级生命周期入口，连接导航激活、认证变化与最终资源清理。
///
/// 页面 View 只表达局部意图；关窗时需要在这里按来源描述清除各来源的内容、认证临时任务，
/// 并借导航路径清空统一停止播放、原生字幕和弹幕资源。
struct AppRootView: View {
    @Environment(\.appearsActive) private var appearsActive
    @StateObject private var windowOwnerHolder: AppWindowOwnerHolder
    private let accountSessionCoordinator: AccountSessionCoordinator
    private let appSettingsModel: AppSettingsModel?
    private let searchHistoryStore: SearchHistoryStore?
    @State private var isAuthenticationPresented = false
    init(
        environment: AppEnvironment? = nil,
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator(),
        systemNowPlayingController: SystemNowPlayingController? = nil,
        appSettingsModel: AppSettingsModel? = nil,
        searchHistoryStore: SearchHistoryStore? = nil
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        self.appSettingsModel = appSettingsModel
        self.searchHistoryStore = searchHistoryStore
        _windowOwnerHolder = StateObject(
            wrappedValue: AppWindowOwnerHolder(
                AppWindowOwner(
                    environment: environment
                        ?? .live(
                            accountSessionCoordinator: accountSessionCoordinator,
                            appSettingsModel: appSettingsModel
                        ),
                    systemNowPlayingController: systemNowPlayingController,
                    recordSearchHistory: { searchHistoryStore?.record($0) }
                )
            )
        )
    }

    init(
        navigationCoordinator: AppNavigationCoordinator,
        browseModel: BrowseViewModel,
        videoModel: VideoViewModel,
        commentsModel: PlaybackCommentsViewModel? = nil,
        danmakuModel: DanmakuControlsViewModel,
        authenticationModel: AuthenticationViewModel,
        historyModel: WatchHistoryViewModel,
        playerContent: AnyView,
        commentAssetURLResolver: @escaping CommentAssetURLResolver = { _, _ in nil },
        commentLinkRouter: @escaping CommentLinkRouter = { _ in nil },
        accountSessionCoordinator: AccountSessionCoordinator = AccountSessionCoordinator(),
        watchProgressConnection: WatchProgressWindowConnection? = nil
    ) {
        self.accountSessionCoordinator = accountSessionCoordinator
        appSettingsModel = nil
        searchHistoryStore = nil
        _windowOwnerHolder = StateObject(
            wrappedValue: AppWindowOwnerHolder(
                AppWindowOwner(
                    navigationCoordinator: navigationCoordinator,
                    browseModel: browseModel,
                    videoModel: videoModel,
                    commentsModel: commentsModel,
                    danmakuModel: danmakuModel,
                    authenticationModel: authenticationModel,
                    historyModel: historyModel,
                    recordSearchHistory: { _ in },
                    playerContent: playerContent,
                    commentAssetURLResolver: commentAssetURLResolver,
                    commentLinkRouter: commentLinkRouter,
                    watchProgressConnection: watchProgressConnection
                )
            )
        )
    }

    var body: some View {
        AppShellView(
            navigationCoordinator: navigationCoordinator,
            sources: windowOwner.sources,
            browseModel: browseModel,
            videoModel: videoModel,
            commentsModel: commentsModel,
            danmakuModel: danmakuModel,
            authenticationModel: authenticationModel,
            historyModel: historyModel,
            trendingSearchModel: windowOwner.trendingSearchModel,
            searchSession: windowOwner.searchSession,
            searchHistory: searchHistoryStore,
            searchSuggestionSource: windowOwner.searchSuggestionSource,
            playerContent: playerContent,
            commentAssetURLResolver: windowOwner.commentAssetURLResolver,
            commentLinkRouter: windowOwner.commentLinkRouter,
            commentShortLinks: windowOwner.commentShortLinks,
            commentImageSaver: windowOwner.commentImageSaver,
            seekPlayback: windowOwner.seekPlayback,
            imagePipeline: windowOwner.imagePipeline,
            isAuthenticationPresented: $isAuthenticationPresented
        )
        .task(id: browseActivation) {
            await browseModel.activate(browseActivation)
        }
        .task(id: commentActivationAID) {
            await applyCommentActivation(aid: commentActivationAID)
        }
        .onAppear {
            windowOwner.synchronizeWatchProgressAccess(historyAccountScope)
            windowOwner.open()
        }
        .onChange(of: appearsActive, initial: true) { _, isActive in
            if isActive {
                windowOwner.markWindowActive()
            }
        }
        .task {
            authenticationModel.restoreIfNeeded()
            await authenticationModel.waitForCurrentTask()
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: authenticationModel.sessionPhase) { _, _ in
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: authenticationModel.state) { _, _ in
            synchronizeBenchmarkAuthentication()
        }
        .onChange(of: isAccountSignedOutConfirmed, initial: true) { _, isConfirmed in
            windowOwner.synchronizeSignedOutConfirmation(isConfirmed)
        }
        .onChange(of: historyAccountScope) { previousScope, scope in
            windowOwner.synchronizeWatchProgressAccess(scope)
            guard AccountSessionScope.isResolvedChange(from: previousScope, to: scope)
            else {
                return
            }
            accountSessionCoordinator.publish(scope)
            // 先通知不要求账户的来源（Browse 重启当前路由），关闭播放，再通知要求账户的来源（观看历史清空并
            // 按需重载）。
            notifyAccountSessionChange(
                generation: accountSessionCoordinator.generation,
                scope: scope,
                requiringAccount: false
            )
            navigationCoordinator.closePlaybackForAuthenticationChange()
            notifyAccountSessionChange(
                generation: accountSessionCoordinator.generation,
                scope: scope,
                requiringAccount: true
            )
        }
        .task(id: accountSessionCoordinator.generation) {
            await synchronizeProcessAccountSession()
        }
        .onChange(of: authenticationModel.resolutionPhase) { previousPhase, phase in
            guard previousPhase == .restoring else { return }
            windowOwner.revalidationParticipants.finishRevalidation(
                phase,
                currentRoute: navigationCoordinator.selectedTab
            )
        }
        .onChange(of: navigationCoordinator.selectedTab) { previousTab, _ in
            windowOwner.sources[previousTab].deactivate()
        }
        .onChange(of: windowOwner.revalidationParticipants.generations) { previous, current in
            guard AccountRevalidationParticipants.requestsRevalidation(from: previous, to: current)
            else { return }
            authenticationModel.revalidate()
        }
        .onDisappear {
            appSettingsModel?.removeAuthenticationOwner(
                windowOwner.benchmarkAuthenticationOwnerID
            )
            navigationCoordinator.resetForWindowClosure()
            windowOwner.sources.resetForWindowClosure()
            authenticationModel.cancelTransientWork()
            commentsModel?.reset()
            windowOwner.close()
        }
    }

    private var windowOwner: AppWindowOwner {
        windowOwnerHolder.owner
    }

    private var navigationCoordinator: AppNavigationCoordinator {
        windowOwner.navigationCoordinator
    }

    private var browseModel: BrowseViewModel {
        windowOwner.browseModel
    }

    private var videoModel: VideoViewModel {
        windowOwner.videoModel
    }

    private var commentsModel: PlaybackCommentsViewModel? {
        windowOwner.commentsModel
    }

    private var danmakuModel: DanmakuControlsViewModel {
        windowOwner.danmakuModel
    }

    private var authenticationModel: AuthenticationViewModel {
        windowOwner.authenticationModel
    }

    private var historyModel: WatchHistoryViewModel {
        windowOwner.historyModel
    }

    private var isAccountSignedOutConfirmed: Bool {
        AccountSignedOutConfirmation.isConfirmed(
            windowScope: authenticationModel.sessionScope,
            resolutionPhase: authenticationModel.resolutionPhase,
            processScope: accountSessionCoordinator.scope
        )
    }

    private var historyAccountScope: AccountSessionScope {
        authenticationModel.sessionScope
    }

    private var playerContent: AnyView {
        windowOwner.playerContent
    }

    /// 窗口关闭后 onDisappear 已注销测速 owner；迟到的同步（如恢复登录完成）不得把它登记回去。
    private func synchronizeBenchmarkAuthentication() {
        guard !windowOwner.isClosed else { return }
        appSettingsModel?.synchronizeAuthentication(
            Self.benchmarkAccess(
                sessionPhase: authenticationModel.sessionPhase,
                isSigningOut: authenticationModel.isSigningOut
            ),
            ownerID: windowOwner.benchmarkAuthenticationOwnerID
        )
    }

    static func benchmarkAccess(
        sessionPhase: AccountSessionPhase,
        isSigningOut: Bool
    ) -> PlaybackRouteBenchmarkAccess {
        if isSigningOut { return .signedOut }
        return switch sessionPhase {
        case .unresolved: .resolving
        case .signedOut: .signedOut
        case .signedIn: .signedIn
        }
    }

    private var commentActivationAID: Int64? {
        guard let currentBVID = navigationCoordinator.currentPlaybackBVID,
            let videoIdentity = videoModel.presentedVideoIdentity,
            videoIdentity.bvid == currentBVID
        else { return nil }
        return videoIdentity.aid
    }

    /// 当前来源要求的 Browse 工作集；穷尽 switch，新增来源时由编译器要求给出映射。
    private var browseActivation: BrowseActivation {
        switch navigationCoordinator.selectedTab {
        case .home:
            .recommendation
        case .popular:
            .popular
        case .search:
            windowOwner.searchSession.browseActivation
        case .history:
            .inactive
        }
    }

    private func applyCommentActivation(aid: Int64?) async {
        // 短链属于上一个视频的简介或评论：视频变化时取消在途解析。
        windowOwner.commentShortLinks.cancel()
        guard let commentsModel else { return }
        guard let aid else {
            commentsModel.reset()
            return
        }
        commentsModel.activateVideo(aid: aid)
        await commentsModel.waitForCurrentRootTask()
    }

    /// 其他窗口换号后，让本窗口先复核再按进程代次通知来源。
    ///
    /// 先丢弃要求账户的来源的内容，让本窗口认证 owner 完成凭据复核和 transport 失效，再按进程代次通知不要求
    /// 账户的来源。要求账户的来源由复核得出的范围变化（`historyAccountScope` 的 onChange）重新加载。
    private func synchronizeProcessAccountSession() async {
        let processGeneration = accountSessionCoordinator.generation
        guard accountSessionCoordinator.scope != historyAccountScope else {
            return
        }
        navigationCoordinator.closePlaybackForAuthenticationChange()
        windowOwner.sources.resetAccountContent()
        authenticationModel.revalidateAfterExternalSessionChange()
        await authenticationModel.waitForCurrentTask()
        guard accountSessionCoordinator.generation == processGeneration else {
            return
        }
        notifyAccountSessionChange(
            generation: processGeneration,
            scope: historyAccountScope,
            requiringAccount: false
        )
    }

    /// 把账户会话变化交给要求账户（或不要求账户）的来源，由来源自己处理。
    private func notifyAccountSessionChange(
        generation: UInt64,
        scope: AccountSessionScope,
        requiringAccount: Bool
    ) {
        for source in windowOwner.sources.ordered where source.requiresAccount == requiringAccount {
            source.synchronizeAccountSession(
                AccountSessionChange(
                    generation: generation,
                    scope: scope,
                    isCurrentRoute: source.id == navigationCoordinator.selectedTab
                )
            )
        }
    }
}

/// 让窗口对象图只在视图身份首次出现时创建一次。
///
/// `@StateObject` 的 autoclosure 只求值一次；`State(initialValue:)` 会在父视图每次重算
/// `AppRootView.init` 时构造并丢弃整套对象图（包括 AVPlayer 与 URLSession）。
@MainActor
private final class AppWindowOwnerHolder: ObservableObject {
    let owner: AppWindowOwner

    init(_ owner: AppWindowOwner) {
        self.owner = owner
    }
}

#Preview {
    AppRootView()
}
