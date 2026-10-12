import SwiftUI

/// 原地刷新时盖在内容顶部的状态胶囊：刷新中显示转圈，失败时显示原因，已显示的内容保持不动。
///
/// 首页推荐、热门、搜索与观看历史共用，出现与消失按 `LoadingStateTransition` 淡入淡出。
package struct RefreshStatusCapsule: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let isRefreshing: Bool
    private let refreshingLabel: String
    private let errorMessage: String?

    package init(isRefreshing: Bool, refreshingLabel: String, errorMessage: String?) {
        self.isRefreshing = isRefreshing
        self.refreshingLabel = refreshingLabel
        self.errorMessage = errorMessage
    }

    package var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(refreshingLabel)
                    .transition(.opacity)
            } else if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: phase)
    }

    private var phase: LoadingVisualPhase {
        if isRefreshing { return .loading }
        return errorMessage == nil ? .idle : .failure
    }
}
