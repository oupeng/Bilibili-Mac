import BiliModels
import Foundation

/// 视频简介 `desc_v2` 的一段：`type` 1 是文字，2 是 @ 用户（`biz_id` 为 MID）。
struct VideoDescriptionSegmentPayload: Decodable, Sendable {
    let rawText: String
    let type: Int?
    let bizID: FlexibleInt64?

    private enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case type
        case bizID = "biz_id"
    }
}

/// 简介正文与链接的拼装：分段完整时按 `desc_v2` 拼出正文并给 @ 段标上用户，否则用 `desc`；
/// 两种来源都再按评论正文规则识别网址、短链、BV/av 号与时间戳。
///
/// 实测 @ 段的 `raw_text` 不带 @，官方显示为「@昵称 」：每个 @ 后跟一个空格，这样拼出的正文与 `desc`
/// 逐字一致。MID 不合法的 @ 段照样显示，只是不成为链接。
enum VideoDescriptionAssembly {
    private static let mentionSegmentType = 2

    static func summary(
        desc: String,
        segments: [VideoDescriptionSegmentPayload?]?
    ) -> (text: String, links: [CommentLink]) {
        // 任一段解码失败时拼出的正文会缺字，整体退回 `desc`。
        guard let segments, !segments.isEmpty, !segments.contains(where: { $0 == nil }) else {
            return (desc, CommentTextLinkDetector.links(in: desc, excluding: []))
        }
        var text = ""
        var length = 0
        var mentions: [CommentLink] = []
        for segment in segments.compactMap(\.self) {
            guard segment.type == mentionSegmentType, !segment.rawText.isEmpty else {
                text += segment.rawText
                length += segment.rawText.utf16.count
                continue
            }
            let token = segment.rawText.hasPrefix("@") ? segment.rawText : "@\(segment.rawText)"
            if let memberID = segment.bizID?.value, memberID > 0, token != "@" {
                let user = CommentAuthor(
                    id: CommentAuthorID(rawValue: String(memberID)),
                    name: String(token.dropFirst())
                )
                mentions.append(
                    CommentLink(
                        range: CommentTextRange(location: length, length: token.utf16.count),
                        target: .member(user)
                    )
                )
            }
            text += token + " "
            length += token.utf16.count + 1
        }
        let links =
            (mentions
            + CommentTextLinkDetector.links(in: text, excluding: mentions.map(\.range)))
            .sorted { $0.range.location < $1.range.location }
        return (text, links)
    }
}
