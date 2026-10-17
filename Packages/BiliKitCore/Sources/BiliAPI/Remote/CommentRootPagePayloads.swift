import BiliModels
import Foundation

/// 根评论分页接口（`/x/v2/reply/wbi/main`）的 data：游标、置顶、热评与本页根评论。
///
/// 单条评论解码失败只丢弃该条；置顶与热评按 ID 与普通评论去重，未结束却没有下一页游标时
/// 整页失败。
struct CommentMainPayload: Decodable, Sendable {
    let cursor: CommentCursorPayload
    let replies: [LossyDecodable<CommentReplyPayload>]
    let topReplies: [LossyDecodable<CommentReplyPayload>]
    let top: CommentTopPayload?
    let upper: CommentUpperPayload?

    private enum CodingKeys: String, CodingKey {
        case cursor
        case replies
        case topReplies = "top_replies"
        case top
        case upper
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decode(CommentCursorPayload.self, forKey: .cursor)
        replies =
            try container.decodeIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .replies
            ) ?? []
        topReplies =
            container.decodeLossyIfPresent(
                [LossyDecodable<CommentReplyPayload>].self,
                forKey: .topReplies
            ) ?? []
        top = container.decodeLossyIfPresent(CommentTopPayload.self, forKey: .top)
        upper = container.decodeLossyIfPresent(CommentUpperPayload.self, forKey: .upper)
    }

    func page(for subject: CommentSubjectIdentity) throws -> CommentRemoteRootPage {
        let uploaderID = upper.map { String($0.mid) }
        let adminPinnedID = top?.admin?.value?.rpid
        let uploaderPinnedID = top?.upper?.value?.rpid
        let pinnedReplies = [top?.admin?.value, top?.upper?.value].compactMap { $0 }
        let candidates =
            pinnedReplies
            + topReplies.compactMap(\.value)
            + replies.compactMap(\.value)
        var seen: Set<CommentID> = []
        var threads: [CommentThread] = []
        for payload in candidates {
            guard
                let thread = try? payload.thread(
                    subject: subject,
                    uploaderID: uploaderID,
                    adminPinnedID: adminPinnedID,
                    uploaderPinnedID: uploaderPinnedID
                ), seen.insert(thread.id).inserted
            else { continue }
            threads.append(thread)
        }

        let nextOffset = cursor.paginationReply?.nextOffset
        if !cursor.isEnd, nextOffset?.isEmpty != false {
            throw BiliAPIError.decodingFailed
        }
        return CommentRemoteRootPage(
            threads: threads,
            totalCount: max(cursor.allCount, threads.count),
            nextOffset: cursor.isEnd ? nil : nextOffset,
            isEnd: cursor.isEnd
        )
    }
}

/// 一页根评论映射后的结果：评论串、总数与下一页游标（结束时为 nil）。
struct CommentRemoteRootPage: Sendable {
    let threads: [CommentThread]
    let totalCount: Int
    let nextOffset: String?
    let isEnd: Bool
}

/// 根评论分页游标：总数、是否结束与下一页偏移。
struct CommentCursorPayload: Decodable, Sendable {
    let allCount: Int
    let isEnd: Bool
    let paginationReply: CommentPaginationReplyPayload?

    private enum CodingKeys: String, CodingKey {
        case allCount = "all_count"
        case isEnd = "is_end"
        case paginationReply = "pagination_reply"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 评论区为空时 cursor 不带 `all_count`。
        allCount = try container.decodeIfPresent(Int.self, forKey: .allCount) ?? 0
        isEnd = try container.decode(Bool.self, forKey: .isEnd)
        paginationReply = container.decodeLossyIfPresent(
            CommentPaginationReplyPayload.self,
            forKey: .paginationReply
        )
    }
}

/// 下一页偏移；接口有时给字符串、有时给整数，统一成字符串原样回传。
struct CommentPaginationReplyPayload: Decodable, Sendable {
    let nextOffset: String

    private enum CodingKeys: String, CodingKey {
        case nextOffset = "next_offset"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .nextOffset) {
            nextOffset = value
        } else {
            nextOffset = String(try container.decode(Int64.self, forKey: .nextOffset))
        }
    }
}

/// 评论区所属 UP 主的 MID，用于标出 UP 主本人的评论。
struct CommentUpperPayload: Decodable, Sendable {
    let mid: Int64
}

/// 管理员置顶与 UP 主置顶的评论，各自单独容错解码。
struct CommentTopPayload: Decodable, Sendable {
    let admin: LossyDecodable<CommentReplyPayload>?
    let upper: LossyDecodable<CommentReplyPayload>?
}
