import BiliModels

/// 认证与内容页同一四态：无凭据、凭据失效（唯一触发账户复核）、本地凭据读不到、风控。
public enum CommentReadError: Error, Sendable, Equatable {
    case authenticationRequired
    case authenticationInvalid
    case authenticationUnavailable
    case requestRestricted
    case serviceRejected(code: Int)
    /// 评论区已关闭；不是可重试的失败。
    case closed
    case transportFailure
    case invalidResponse
    case unavailable
}

extension CommentReadError {
    /// 只有凭据失效需要窗口复核账户会话；评论 ViewModel 据此递增复核计数，不各自比较错误值。
    public var requiresAccountRevalidation: Bool {
        self == .authenticationInvalid
    }
}

/// API adapter 生成并消费的不透明主评论分页令牌。
public struct CommentContinuation: Sendable, Equatable, Hashable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct CommentRootPage: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let isEnd: Bool

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        isEnd: Bool
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.isEnd = isEnd
    }
}

public struct CommentReplyPage: Sendable, Equatable {
    public let rootID: CommentID
    public let replies: [Comment]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int

    public init(
        rootID: CommentID,
        replies: [Comment],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int
    ) {
        self.rootID = rootID
        self.replies = replies
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = totalCount
    }
}

/// 匿名只读评论 port；endpoint、WBI 和远端 DTO 留在具体 adapter。
public protocol CommentRepository: Sendable {
    func rootComments(
        for subject: CommentSubjectIdentity,
        sort: CommentSort,
        after continuation: CommentContinuation?
    ) async throws -> CommentRootPage

    func replies(
        for subject: CommentSubjectIdentity,
        rootID: CommentID,
        page: Int,
        pageSize: Int
    ) async throws -> CommentReplyPage
}

public enum CommentPaginationTermination: Sendable, Equatable {
    case serverEnd
    case emptyPage
    case duplicatePage
}

public struct CommentRootBatch: Sendable, Equatable {
    public let threads: [CommentThread]
    public let totalCount: Int
    public let continuation: CommentContinuation?
    public let termination: CommentPaginationTermination?

    public init(
        threads: [CommentThread],
        totalCount: Int,
        continuation: CommentContinuation?,
        termination: CommentPaginationTermination?
    ) {
        self.threads = threads
        self.totalCount = totalCount
        self.continuation = continuation
        self.termination = termination
    }
}

public struct CommentReplyBatch: Sendable, Equatable {
    public let rootID: CommentID
    public let replies: [Comment]
    public let pageNumber: Int
    public let pageSize: Int
    public let totalCount: Int
    public let isEnd: Bool

    public init(
        rootID: CommentID,
        replies: [Comment],
        pageNumber: Int,
        pageSize: Int,
        totalCount: Int,
        isEnd: Bool
    ) {
        self.rootID = rootID
        self.replies = replies
        self.pageNumber = pageNumber
        self.pageSize = pageSize
        self.totalCount = totalCount
        self.isEnd = isEnd
    }
}
