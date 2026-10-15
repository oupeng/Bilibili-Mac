import SwiftUI

/// 将历史页面可见性连接到 ViewModel 的加载与路由停用语义。
///
/// `.task` 触发并等待模型当前请求。真正的来源 Tab 停用由 App composition 通知模型；
/// 播放详情只是覆盖本页面，不应误取消分页。登出清理仍由窗口级 `reset` 边界负责；凭据失效经
/// 模型的 `authenticationRevalidationGeneration` 交给 App 统一复核。
public struct WatchHistoryView<LoadedContent: View>: View {
    private let model: WatchHistoryViewModel
    private let makeLoadedContent: (LoadedHistoryContent) -> LoadedContent
    private let onSelect: (String) -> Void

    public init(
        model: WatchHistoryViewModel,
        @ViewBuilder makeLoadedContent: @escaping (LoadedHistoryContent) -> LoadedContent,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.makeLoadedContent = makeLoadedContent
        self.onSelect = onSelect
    }

    public var body: some View {
        WatchHistoryContentView(
            model: model,
            makeLoadedContent: makeLoadedContent,
            onSelect: onSelect
        )
        .task {
            model.loadIfNeeded()
            await model.waitForCurrentTask()
        }
    }
}
