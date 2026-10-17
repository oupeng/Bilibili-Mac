import Foundation

/// 封面左下角的一项指标（播放、弹幕数等）：已格式化的文字与 SF Symbol 名。
public struct NativeVideoCardMetric: Equatable, Sendable {
    public let text: String
    public let systemImage: String

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

/// 页脚尾部文字的样式。
public enum NativeVideoCardFooterTrailingStyle: Equatable, Sendable {
    /// 靠右的普通文字，前面可带小图标。
    case plain
    /// 品牌色描边胶囊，排在页脚最前（首页推荐理由），页脚文字随后。
    case brandOutlinedCapsule
}

/// AppKit 卡片唯一消费的、无业务语义的展示值。
///
/// Feature 或 composition adapter 负责图片 URL 优化、数字/日期/进度格式化与 AX 文案；
/// renderer 不读取 endpoint model，也不推断任何业务状态。
public struct NativeVideoCardPresentation: Equatable, Sendable {
    public let id: String
    public let title: String
    public let coverURL: URL?
    public let avatarURL: URL?
    public let showsAvatar: Bool
    public let coverMetrics: [NativeVideoCardMetric]
    public let coverTrailingText: String?
    public let footerLeadingText: String
    public let footerTrailingText: String?
    /// 尾部文字前的小图标（SF Symbol 名），只用于普通样式。
    public let footerTrailingSymbolName: String?
    public let footerTrailingStyle: NativeVideoCardFooterTrailingStyle
    public let accessibilityLabel: String
    public let accessibilityHelp: String?

    public init(
        id: String,
        title: String,
        coverURL: URL?,
        avatarURL: URL?,
        showsAvatar: Bool,
        coverMetrics: [NativeVideoCardMetric] = [],
        coverTrailingText: String? = nil,
        footerLeadingText: String,
        footerTrailingText: String? = nil,
        footerTrailingSymbolName: String? = nil,
        footerTrailingStyle: NativeVideoCardFooterTrailingStyle = .plain,
        accessibilityLabel: String,
        accessibilityHelp: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.avatarURL = avatarURL
        self.showsAvatar = showsAvatar
        // 封面只有两个指标位，多出的丢弃。
        self.coverMetrics = Array(coverMetrics.prefix(2))
        self.coverTrailingText = coverTrailingText
        self.footerLeadingText = footerLeadingText
        self.footerTrailingText = footerTrailingText
        self.footerTrailingSymbolName = footerTrailingSymbolName
        self.footerTrailingStyle = footerTrailingStyle
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
    }
}

/// 复用卡片的身份：视频 ID 加卡片自己的配置代次，异步取图回来时据此判断卡片是否已改配。
struct NativeVideoReuseIdentity: Equatable {
    let itemID: String
    let generation: UInt64
}

/// 取图结果能否写回卡片：未取消，且卡片当前身份与发起时相同；否则丢弃结果。
enum NativeVideoImageApplicationGate {
    static func accepts(
        currentIdentity: NativeVideoReuseIdentity?,
        resultIdentity: NativeVideoReuseIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentIdentity == resultIdentity
    }
}
