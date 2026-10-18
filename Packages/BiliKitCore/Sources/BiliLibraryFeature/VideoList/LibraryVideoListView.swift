import BiliApplication
import BiliUI
import BiliVideoCollectionUI
import SwiftUI

/// 资料库列表来源（观看历史、稍后再看）共用的根视图：按账户呈现状态显示登录门槛，已登录时显示列表内容与
/// 原生网格，把页面可见性连接到 ViewModel 的加载与路由停用语义，并在工具栏提供刷新。
///
/// `.task` 只在已登录、列表内容出现时触发并等待模型当前请求。真正的来源 Tab 停用由 App composition
/// 通知模型；播放详情只是覆盖本页面，不应误取消分页。登出清理仍由窗口级 `reset` 边界负责；凭据失效经
/// 模型的 `authenticationRevalidationGeneration` 交给 App 统一复核。登录与账号页面由 App 注入的
/// `onPresentAuthentication` 打开。滚动位置、回顶请求与图片管线属于 App 窗口，经
/// `NativeVideoGridHostContext` 原样交给网格。已登录时工具栏 primaryAction 依次是来源给的控件（稍后再看的排序与
/// 筛选，由 App 宿主）与刷新按钮，放在同一组里保证顺序。
struct LibraryVideoListView<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: View {
    let model: LibraryVideoListModel<Item, Cursor>
    let text: LibraryVideoListText
    let card: (Item, Locale) -> NativeVideoCardPresentation
    let accountState: AccountPresentationState
    let gridHost: NativeVideoGridHostContext
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    /// 排在刷新按钮之前的工具栏控件；没有时为 nil。
    var toolbarControls: AnyView? = nil
    /// 刷新按钮的动作；没有时直接 `model.reload()`。
    ///
    /// 稍后再看经会话刷新，由会话决定条件。
    var refresh: (() -> Void)? = nil

    var body: some View {
        AccountGateView(
            state: accountState,
            signInTitle: text.signInTitle,
            signInDescription: text.signInDescription,
            onPresentAuthentication: onPresentAuthentication
        ) {
            LibraryVideoListContentView(
                model: model,
                text: text,
                card: card,
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
                ToolbarItemGroup(placement: .primaryAction) {
                    if let toolbarControls {
                        toolbarControls
                    }
                    LibraryRefreshButton(model: model, refresh: refresh ?? model.reload)
                }
            }
        }
    }
}

/// 单独成一个 View：只有它读取 `isBusy`，加载状态变化时不让整个根视图重新求值。
private struct LibraryRefreshButton<Item: Sendable & Equatable, Cursor: Equatable & Sendable>: View
{
    @Environment(\.locale) private var locale
    let model: LibraryVideoListModel<Item, Cursor>
    let refresh: () -> Void

    var body: some View {
        Button {
            refresh()
        } label: {
            Label(
                LibraryFeatureStrings.localized("刷新", locale: locale),
                systemImage: "arrow.clockwise"
            )
        }
        .disabled(model.isBusy)
    }
}
