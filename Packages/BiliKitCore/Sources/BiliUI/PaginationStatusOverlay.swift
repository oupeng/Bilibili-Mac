import SwiftUI

/// 列表底部的分页状态胶囊：加载更多时转圈，失败时显示原因与可选重试，需要用户显式继续时显示按钮。
///
/// 首页推荐、热门、搜索与观看历史共用同一种样式（与顶部 `RefreshStatusCapsule` 一致的材质胶囊）。
/// 只负责排版；标签与动作由调用方的 Feature 本地化并提供，是否给重试由调用方按 `isRetryable` 决定。
package struct PaginationStatusOverlay: View {
    package enum Status {
        case idle
        /// `label` 只作为转圈的读屏标签，不占可见宽度。
        case loadingMore(label: String)
        /// `retry` 为 nil 时只说明原因（重试不会改变结果，或已没有下一页）。
        case failed(message: String, retry: (() -> Void)?)
        /// 空页或全重复页之后不自动翻页，由用户点按继续。
        case manualLoadMore(title: String, action: () -> Void)
    }

    private typealias Geometry = StatusCapsuleGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    private let status: Status

    package init(_ status: Status) {
        self.status = status
    }

    package var body: some View {
        ZStack {
            switch status {
            case .idle:
                EmptyView()
            case .loadingMore(let label):
                ProgressView()
                    .controlSize(.small)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(label)
                    .transition(.opacity)
            case .failed(let message, let retry):
                HStack(spacing: Geometry.spacing) {
                    Text(message)
                        .lineLimit(Geometry.messageLineLimit)
                    if let retry {
                        Button(BiliUIStrings.localized("重试", locale: locale), action: retry)
                    }
                }
                .font(.caption)
                .padding(Geometry.contentPadding)
                .background(.regularMaterial, in: Capsule())
                .transition(.opacity)
            case .manualLoadMore(let title, let action):
                Button(title, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(Geometry.contentPadding)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Geometry.horizontalInset)
        .padding(.bottom, Geometry.bottomInset)
        .animation(LoadingStateTransition.animation(reduceMotion: reduceMotion), value: phase)
    }

    private var phase: LoadingVisualPhase {
        switch status {
        case .idle: .idle
        case .loadingMore: .loading
        case .failed: .failure
        case .manualLoadMore: .content
        }
    }
}
