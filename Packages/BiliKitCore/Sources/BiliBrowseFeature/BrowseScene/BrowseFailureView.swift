import BiliApplication
import SwiftUI

struct BrowseFailureView: View {
    let title: String
    let message: String
    /// nil 时不提供重试（需要登录、内容不存在或不可见）。
    let retry: (() -> Void)?

    init(error: ContentApplicationError, retry: @escaping () -> Void) {
        title = error.displayTitle
        message = error.displayMessage
        self.retry = error.isRetryable ? retry : nil
    }

    init(failure: VideoLoadFailure, retry: @escaping () -> Void) {
        title = failure.title
        message = failure.message
        self.retry = failure.isRetryable ? retry : nil
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button(BrowseFeatureStrings.localized("重试"), action: retry)
                    .buttonStyle(.borderedProminent)
            }
        }
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
            error.displayTitle
        case .playback:
            BrowseFeatureStrings.localized("无法准备播放")
        }
    }

    public var message: String {
        switch self {
        case .content(let error):
            error.displayMessage
        case .playback:
            BrowseFeatureStrings.localized("当前媒体轨道或网络响应无法交给系统播放器。")
        }
    }
}

extension ContentApplicationError {
    var displayTitle: String {
        switch self {
        case .authenticationRequired:
            BrowseFeatureStrings.localized("需要登录")
        case .authenticationInvalid:
            BrowseFeatureStrings.localized("登录状态已失效")
        case .authenticationUnavailable:
            BrowseFeatureStrings.localized("无法读取登录状态")
        case .requestRestricted:
            BrowseFeatureStrings.localized("请求受到限制")
        case .serviceRejected:
            BrowseFeatureStrings.localized("无法完成请求")
        case .contentUnavailable:
            BrowseFeatureStrings.localized("内容不存在或不可见")
        case .unsupportedMedia:
            BrowseFeatureStrings.localized("没有可播放的游客轨道")
        case .fullViewingEntitlementRequired:
            BrowseFeatureStrings.localized("当前账户没有完整观看权益")
        default:
            BrowseFeatureStrings.localized("无法加载内容")
        }
    }

    var displayMessage: String {
        switch self {
        case .invalidRequest:
            BrowseFeatureStrings.localized("请求参数无效，请重新选择内容。")
        case .authenticationRequired:
            BrowseFeatureStrings.localized("该内容需要登录后查看。")
        case .authenticationInvalid:
            BrowseFeatureStrings.localized("本地登录状态已失效，正在重新确认账户会话。")
        case .authenticationUnavailable:
            BrowseFeatureStrings.localized("无法安全读取本地登录凭据，请稍后重试。")
        case .requestRestricted:
            BrowseFeatureStrings.localized("服务可能返回了风控页，请降低请求频率后重试。")
        case .contentUnavailable:
            BrowseFeatureStrings.localized("该内容可能已被删除、仍在审核，或只对部分用户可见。")
        case .serviceRejected(let code):
            BrowseFeatureStrings.localized("服务暂时无法完成请求（代码 \(code)）。")
        case .transportFailure:
            BrowseFeatureStrings.localized("请检查网络连接后重试。")
        case .unsupportedMedia:
            BrowseFeatureStrings.localized("该视频在当前服务授权范围内没有 AVPlayer 可用的 AVC/AAC 轨道。")
        case .fullViewingEntitlementRequired:
            BrowseFeatureStrings.localized("当前账户没有完整观看权益。")
        case .playbackUnavailable:
            BrowseFeatureStrings.localized("服务没有返回可播放媒体，请稍后重试。")
        case .invalidResponse:
            BrowseFeatureStrings.localized("接口数据与当前客户端预期不一致，请稍后重试。")
        case .unavailable:
            BrowseFeatureStrings.localized("暂时无法完成请求，请稍后重试。")
        }
    }
}
