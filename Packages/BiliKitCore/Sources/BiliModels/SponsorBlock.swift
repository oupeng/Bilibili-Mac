import Foundation

/// SponsorBlock 视频片段分类
public enum SponsorBlockCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case sponsor
    case intro
    case outro
    case interaction
    case poi
    case musicOfftopic = "music_offtopic"
    case filler

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sponsor:
            return "赞助 / 恰饭"
        case .intro:
            return "片头 / 动画"
        case .outro:
            return "片尾 / 鸣谢"
        case .interaction:
            return "互动提醒"
        case .poi:
            return "看点 / 重点"
        case .musicOfftopic:
            return "非音乐片段"
        case .filler:
            return "无意义 / 填充"
        }
    }
}

/// SponsorBlock 动作类型（例如：跳过、播放提醒、静音等）
public enum SponsorBlockActionType: String, Sendable, Codable {
    case skip
    case mute
    case poi
    case full
}

/// SponsorBlock 片段信息
public struct SponsorSegment: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let category: SponsorBlockCategory
    public let startSeconds: Double
    public let endSeconds: Double
    public let actionType: SponsorBlockActionType

    public init(
        id: String,
        category: SponsorBlockCategory,
        startSeconds: Double,
        endSeconds: Double,
        actionType: SponsorBlockActionType = .skip
    ) {
        self.id = id
        self.category = category
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.actionType = actionType
    }
}

/// SponsorBlock 全局偏好设置
public struct SponsorBlockSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var serverURL: String
    public var enabledCategories: Set<SponsorBlockCategory>

    public static let defaultServerURL = "https://bsb.hanydd.com"

    public static let `default` = SponsorBlockSettings(
        isEnabled: true,
        serverURL: defaultServerURL,
        enabledCategories: [.sponsor, .intro, .outro, .interaction]
    )

    public init(
        isEnabled: Bool = true,
        serverURL: String = defaultServerURL,
        enabledCategories: Set<SponsorBlockCategory> = [.sponsor, .intro, .outro, .interaction]
    ) {
        self.isEnabled = isEnabled
        self.serverURL = serverURL.isEmpty ? Self.defaultServerURL : serverURL
        self.enabledCategories = enabledCategories
    }
}
