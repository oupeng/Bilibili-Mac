import BiliAuthFeature
import BiliBrowseFeature
import BiliLibraryFeature
import SwiftUI

struct WatchLaterTabRoot: View {
    let model: WatchLaterViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("稍后再看")
            .toolbar {
                if case .signedIn = accountState {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.reload()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn:
            WatchLaterView(
                model: model,
                makeLoadedContent: { content in
                    WatchLaterNativeGridView(
                        content: content,
                        scrollOffsetY: $scrollOffsetY,
                        scrollReset: $scrollReset,
                        imagePipeline: imagePipeline
                    )
                    .ignoresSafeArea(.container, edges: .top)
                },
                onSelect: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看稍后再看", systemImage: "person.crop.circle")
            } description: {
                Text("稍后再看列表只在登录期间加载。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label("暂时无法确认登录状态", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct FavoritesTabRoot: View {
    let model: FavoritesViewModel
    let accountState: AccountPresentationState
    @Binding var scrollOffsetY: CGFloat
    @Binding var scrollReset: NativeVideoGridScrollResetState
    let imagePipeline: NativeVideoImagePipeline
    let onSelect: (String) -> Void
    let onPresentAuthentication: () -> Void
    let onAuthenticationRequired: () -> Void

    var body: some View {
        content
            .navigationTitle("收藏")
            .toolbar {
                if case .signedIn(let account) = accountState {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.reloadFolders(mid: account.id)
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch accountState {
        case .signedIn(let account):
            FavoritesView(
                model: model,
                userMID: account.id,
                makeLoadedContent: { content in
                    FavoritesNativeGridView(
                        content: content,
                        scrollOffsetY: $scrollOffsetY,
                        scrollReset: $scrollReset,
                        imagePipeline: imagePipeline
                    )
                    .ignoresSafeArea(.container, edges: .top)
                },
                onSelect: onSelect,
                onAuthenticationRequired: onAuthenticationRequired
            )
        case .signedOut:
            ContentUnavailableView {
                Label("登录后查看收藏夹", systemImage: "person.crop.circle")
            } description: {
                Text("你的收藏夹内容只在登录期间加载。")
            } actions: {
                Button("登录", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        case .resolving:
            ProgressView("正在检查登录状态…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                Label("暂时无法确认登录状态", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text("请在账号页面重试。")
            } actions: {
                Button("查看账号状态", action: onPresentAuthentication)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
