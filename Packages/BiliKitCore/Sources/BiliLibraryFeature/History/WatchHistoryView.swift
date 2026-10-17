import BiliApplication
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 观看历史来源的根视图：按账户呈现状态显示登录门槛，已登录时显示历史内容与原生网格，把页面可见性连接到
/// ViewModel 的加载与路由停用语义，并在工具栏提供刷新。
///
/// `.task` 只在已登录、历史内容出现时触发并等待模型当前请求。真正的来源 Tab 停用由 App composition
/// 通知模型；播放详情只是覆盖本页面，不应误取消分页。登出清理仍由窗口级 `reset` 边界负责；凭据失效经
/// 模型的 `authenticationRevalidationGeneration` 交给 App 统一复核。登录与账号页面由 App 注入的
/// `onPresentAuthentication` 打开。滚动位置、回顶请求与图片管线属于 App 窗口，经
/// `NativeVideoGridHostContext` 原样交给网格。
public struct WatchHistoryView: View {
    @Environment(\.locale) private var locale
    private let model: WatchHistoryViewModel
    private let accountState: AccountPresentationState
    private let gridHost: NativeVideoGridHostContext
    private let onSelect: (String) -> Void
    private let onPresentAuthentication: () -> Void

    public init(
        model: WatchHistoryViewModel,
        accountState: AccountPresentationState,
        gridHost: NativeVideoGridHostContext,
        onSelect: @escaping (String) -> Void,
        onPresentAuthentication: @escaping () -> Void
    ) {
        self.model = model
        self.accountState = accountState
        self.gridHost = gridHost
        self.onSelect = onSelect
        self.onPresentAuthentication = onPresentAuthentication
    }

    public var body: some View {
        AccountGateView(
            state: accountState,
            signInTitle: LibraryFeatureStrings.localized("登录后查看观看历史", locale: locale),
            signInDescription: LibraryFeatureStrings.localized(
                "观看历史只在登录期间加载，不会保存到本机。",
                locale: locale
            ),
            onPresentAuthentication: onPresentAuthentication
        ) {
            WatchHistoryContentView(
                model: model,
                gridHost: gridHost,
                onSelect: onSelect
            )
            .task {
                model.loadIfNeeded()
                await model.waitForCurrentTask()
            }
        }
        .toolbar {
            if case .signedIn = accountState {
                ToolbarItem(placement: .primaryAction) {
                    WatchHistoryRefreshButton(model: model)
                }
            }
        }
    }
}

/// 单独成一个 View：只有它读取 `isBusy`，加载状态变化时不让整个根视图重新求值。
private struct WatchHistoryRefreshButton: View {
    @Environment(\.locale) private var locale
    let model: WatchHistoryViewModel

    var body: some View {
        Button {
            model.reload()
        } label: {
            Label(
                LibraryFeatureStrings.localized("刷新", locale: locale),
                systemImage: "arrow.clockwise"
            )
        }
        .disabled(model.isBusy)
    }
}
