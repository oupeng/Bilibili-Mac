import BiliModels
import BiliNetworking
import Foundation

/// 字幕目录（`/x/player/wbi/v2`）的 `data`，由 `BiliAPIClient.subtitleResources` 映射为
/// `SubtitleRemoteTrack` 列表。
///
/// `need_login_subtitle` 为 true 时按需要登录失败；超过 128 轨、轨道字段不合规或 ID
/// 重复时整份目录无效，没有正文地址的轨道跳过。
struct SubtitleCatalogPayload: Decodable, Sendable {
    let needsLogin: Bool?
    let subtitle: SubtitleCollectionPayload?

    private enum CodingKeys: String, CodingKey {
        case needsLogin = "need_login_subtitle"
        case subtitle
    }

    func resources() throws -> [SubtitleRemoteTrack] {
        guard needsLogin != true else {
            throw BiliAPIError.authorizationRequired
        }
        let payloads = subtitle?.subtitles ?? []
        guard payloads.count <= 128 else {
            throw BiliAPIError.invalidSubtitleData
        }

        var seen = Set<String>()
        return try payloads.compactMap { payload in
            guard let resource = try payload.resourceIfAvailable() else {
                return nil
            }
            guard seen.insert(resource.track.id).inserted else {
                throw BiliAPIError.invalidSubtitleData
            }
            return resource
        }
    }
}

/// 字幕目录的 `subtitle`：各语言轨道。
struct SubtitleCollectionPayload: Decodable, Sendable {
    let subtitles: [SubtitleTrackPayload]
}

/// 字幕目录的一项，映射为 `SubtitleTrack` 与正文地址。
struct SubtitleTrackPayload: Decodable, Sendable {
    let numericID: Int64?
    let stringID: String?
    let languageCode: String
    let displayName: String
    /// 正文地址：协议相对地址补 `https:`，再经 `SubtitleURLPolicy` 复核，
    /// 不合规时整份目录以不可信来源失败（见 SECURITY-MODEL §4）。
    let subtitleURL: String
    let aiType: Int?
    let aiStatus: Int?

    private enum CodingKeys: String, CodingKey {
        case numericID = "id"
        case stringID = "id_str"
        case languageCode = "lan"
        case displayName = "lan_doc"
        case subtitleURL = "subtitle_url"
        case aiType = "ai_type"
        case aiStatus = "ai_status"
    }

    func resourceIfAvailable() throws -> SubtitleRemoteTrack? {
        guard let subtitleURL = Self.nonempty(subtitleURL) else {
            return nil
        }
        let id =
            stringID.flatMap(Self.nonempty)
            ?? numericID.map(String.init)
        guard let id,
            id.count <= 128,
            let languageCode = Self.nonempty(languageCode),
            languageCode.count <= 64,
            let displayName = Self.nonempty(displayName),
            displayName.count <= 128,
            let url = Self.url(subtitleURL)
        else {
            throw BiliAPIError.invalidSubtitleData
        }
        guard SubtitleURLPolicy().allows(url) else {
            throw BiliAPIError.untrustedSubtitleOrigin
        }
        return SubtitleRemoteTrack(
            track: SubtitleTrack(
                id: id,
                languageCode: languageCode,
                displayName: displayName,
                kind: trackKind(languageCode: languageCode)
            ),
            url: url
        )
    }

    /// AI 语义由语言标记与已知字段值共同决定。
    ///
    /// `ai-` 前缀且 `ai_status` 为 2 时，`ai_type` 0 为识别、1 为翻译。异常或缺失组合保持 unknown：
    /// 字段无法确认来源时，不给轨道加 AI 标签或机器生成特征，宁可按目录原名显示，也不错标来源。
    private func trackKind(languageCode: String) -> SubtitleTrackKind {
        let normalizedLanguageCode = languageCode.lowercased()
        if normalizedLanguageCode.hasPrefix("ai-"),
            normalizedLanguageCode.count > 3,
            aiStatus == 2
        {
            switch aiType {
            case 0:
                return .automaticTranscription
            case 1:
                return .automaticTranslation
            default:
                return .unknown
            }
        }
        switch (normalizedLanguageCode, aiType, aiStatus) {
        case ("zh", 0, 0):
            return .standard
        default:
            return .unknown
        }
    }

    private static func nonempty(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func url(_ value: String) -> URL? {
        URL(string: RemoteURLString.resolvingProtocolRelative(value))
    }
}

/// 字幕正文 JSON，由 `BiliSubtitleRepository` 解码为 `SubtitleCue` 列表。
///
/// 超过 20000 条、文字总数超过 1000000 或开始时间倒退时整份无效。
struct SubtitleBodyPayload: Decodable, Sendable {
    let body: [SubtitleCuePayload]

    func cues() throws -> [SubtitleCue] {
        guard body.count <= 20_000 else {
            throw BiliAPIError.invalidSubtitleData
        }
        var previousStart = -Double.infinity
        var totalTextLength = 0
        return try body.map { payload in
            let cue = try payload.cue()
            guard cue.startSeconds >= previousStart else {
                throw BiliAPIError.invalidSubtitleData
            }
            previousStart = cue.startSeconds
            totalTextLength += cue.text.count
            guard totalTextLength <= 1_000_000 else {
                throw BiliAPIError.invalidSubtitleData
            }
            return cue
        }
    }
}

/// 字幕正文的一条：起止秒数与文字；时间非有限、起止倒置、结束超过 24 小时、文字为空或超过 4096
/// 字时整份无效。
struct SubtitleCuePayload: Decodable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let content: String

    private enum CodingKeys: String, CodingKey {
        case startSeconds = "from"
        case endSeconds = "to"
        case content
    }

    func cue() throws -> SubtitleCue {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard startSeconds.isFinite,
            endSeconds.isFinite,
            startSeconds >= 0,
            endSeconds > startSeconds,
            endSeconds <= 86_400,
            !text.isEmpty,
            text.count <= 4_096
        else {
            throw BiliAPIError.invalidSubtitleData
        }
        return SubtitleCue(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            text: text
        )
    }
}

/// 字幕轨与其正文地址；地址只保存在 `BiliSubtitleRepository` 内，不越过 adapter。
struct SubtitleRemoteTrack: Sendable {
    let track: SubtitleTrack
    let url: URL
}
