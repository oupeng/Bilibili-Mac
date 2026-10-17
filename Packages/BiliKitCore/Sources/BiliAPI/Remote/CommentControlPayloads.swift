import Foundation

/// 评论的附加控制信息：IP 属地与 UP 主是否点赞。
struct CommentReplyControlPayload: Decodable, Sendable {
    let location: String?
    let upLike: Bool?

    var normalizedLocation: String? {
        guard let location else { return nil }
        return
            location
            .replacingOccurrences(of: "IP属地：", with: "")
            .replacingOccurrences(of: "IP属地:", with: "")
    }

    private enum CodingKeys: String, CodingKey {
        case location
        case upLike = "up_like"
    }
}

/// 评论是否被折叠；被折叠的评论映射为不可见占位。
struct CommentFolderPayload: Decodable, Sendable {
    let isFolded: Bool?

    private enum CodingKeys: String, CodingKey {
        case isFolded = "is_folded"
    }
}
