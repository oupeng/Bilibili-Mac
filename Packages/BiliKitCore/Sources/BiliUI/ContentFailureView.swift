import SwiftUI

/// 整页加载失败的唯一视图：标题、说明，以及可选的重试。
///
/// 只负责排版；文案来自 `ContentFailureText` 或调用方自己的失败类型（播放页的 `VideoLoadFailure`）。
/// 调用方只在错误可重试（`isRetryable`）时传入重试动作。
package struct ContentFailureView: View {
    @Environment(\.locale) private var locale
    private let title: String
    private let message: String
    /// nil 时不提供重试（需要登录、内容不存在或不可见等重试不会改变结果的失败）。
    private let retry: (() -> Void)?

    package init(title: String, message: String, retry: (() -> Void)?) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    package var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button(BiliUIStrings.localized("重试", locale: locale), action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
