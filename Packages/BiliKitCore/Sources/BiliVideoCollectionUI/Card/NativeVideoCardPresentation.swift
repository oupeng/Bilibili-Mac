import Foundation

public struct NativeVideoCardMetric: Equatable, Sendable {
    public let text: String
    public let systemImage: String

    public init(text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }
}

public enum NativeVideoCardFooterTrailingStyle: Equatable, Sendable {
    case plain
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

struct NativeVideoReuseIdentity: Equatable {
    let itemID: String
    let generation: UInt64
}

enum NativeVideoImageApplicationGate {
    static func accepts(
        currentIdentity: NativeVideoReuseIdentity?,
        resultIdentity: NativeVideoReuseIdentity,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && currentIdentity == resultIdentity
    }
}
