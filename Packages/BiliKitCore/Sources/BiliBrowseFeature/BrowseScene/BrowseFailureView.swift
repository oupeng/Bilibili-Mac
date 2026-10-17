import BiliApplication
import BiliUI
import SwiftUI

/// Browse 页面（推荐、热门、搜索）的整页失败：把内容失败交给共享的 `ContentFailureView`。
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

    var body: some View {
        ContentFailureView(title: title, message: message, retry: retry)
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
