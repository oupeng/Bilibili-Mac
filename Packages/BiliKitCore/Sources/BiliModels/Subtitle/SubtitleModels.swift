/// 字幕轨的来源：`standard` 为人工中文字幕；`automaticTranscription` 为 AI 识别原声生成的字幕，
/// `automaticTranslation` 为 AI 把字幕机器翻译成其他语言；字段组合无法确定时为 `unknown`。
///
/// 识别与翻译分开，是因为系统字幕菜单按两者给出不同的本地化标注（见 BiliPlayback 的
/// `NativeSubtitleSource`）。
public enum SubtitleTrackKind: Sendable, Equatable {
    case standard
    case automaticTranscription
    case automaticTranslation
    case unknown

    /// AI 生成（识别或翻译）的字幕；用户可见标签与语言标签按 AI 字幕处理。
    public var isAutomatic: Bool {
        switch self {
        case .automaticTranscription, .automaticTranslation:
            true
        case .standard, .unknown:
            false
        }
    }
}

/// 字幕目录（`/x/player/wbi/v2`）里的一条字幕轨，供界面选择；不携带正文地址。
///
/// 正文地址映射时已过 `SubtitleURLPolicy`，只留在 BiliAPI 的字幕仓库里按 `id` 取用，取用前再查一次
/// （见 SECURITY-MODEL §4）。
public struct SubtitleTrack: Sendable, Equatable, Identifiable {
    public let id: String
    public let languageCode: String
    public let displayName: String
    public let kind: SubtitleTrackKind

    public init(
        id: String,
        languageCode: String,
        displayName: String,
        kind: SubtitleTrackKind
    ) {
        self.id = id
        self.languageCode = languageCode
        self.displayName = displayName
        self.kind = kind
    }
}

/// 一条字幕：半开区间 `[startSeconds, endSeconds)` 与去掉首尾空白的正文。
///
/// 解码时拒绝非有限、负数或超过 24 小时的时间与空正文，整份字幕按开始时间非递减。
public struct SubtitleCue: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }

    public func contains(positionSeconds: Double) -> Bool {
        startSeconds <= positionSeconds && positionSeconds < endSeconds
    }
}
