import BiliApplication
import BiliUI
import SwiftUI

/// Browse 页面（推荐、热门、搜索、播放页）的整页失败：把 Browse 的失败类型交给共享的 `ContentFailureView`。
struct BrowseFailureView: View {
    let title: String
    let message: String
    /// nil 时不提供重试（需要登录、内容不存在或不可见）。
    let retry: (() -> Void)?

    init(error: ContentApplicationError, retry: @escaping () -> Void) {
        let text = error.browseFailureText
        title = text.title
        message = text.message
        self.retry = error.isRetryable ? retry : nil
    }

    init(failure: VideoLoadFailure, retry: @escaping () -> Void) {
        title = failure.title
        message = failure.message
        self.retry = failure.isRetryable ? retry : nil
    }

    var body: some View {
        ContentFailureView(title: title, message: message, retry: retry)
    }
}

extension VideoLoadFailure {
    public var isRetryable: Bool {
        switch self {
        case .content(let error):
            error.isRetryable
        case .playback:
            true
        }
    }

    public var title: String {
        switch self {
        case .content(let error):
            error.browseFailureText.title
        case .playback:
            BrowseFeatureStrings.localized("无法准备播放")
        }
    }

    public var message: String {
        switch self {
        case .content(let error):
            error.browseFailureText.message
        case .playback:
            BrowseFeatureStrings.localized("当前媒体轨道或网络响应无法交给系统播放器。")
        }
    }
}

extension ContentApplicationError {
    /// Browse 不跟踪账户复核进度；没有专属标题的失败统称“无法加载内容”。
    var browseFailureText: ContentFailureText {
        ContentFailureText(
            error: self,
            fallbackTitle: BrowseFeatureStrings.localized("无法加载内容")
        )
    }
}
