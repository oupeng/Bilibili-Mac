import Foundation

public struct CommentSubjectIdentity: Sendable, Equatable, Hashable {
    public let type: Int
    public let oid: Int64

    public static func video(aid: Int64) -> Self {
        Self(type: 1, oid: aid)
    }

    public init(type: Int, oid: Int64) {
        self.type = type
        self.oid = oid
    }
}

public enum CommentSort: Sendable, Equatable, Hashable {
    case hot
    case latest
}

public struct CommentID: Sendable, Equatable, Hashable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }
}

public struct CommentAuthorID: Sendable, Equatable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// 只由十进制数字组成的正整数 MID；其他形状（含符号、空白、溢出）为 nil。
    ///
    /// 成员外链与评论作者进入空间共用这一判定。
    public var memberID: Int64? {
        Int64(positiveDecimal: rawValue)
    }
}

extension Int64 {
    /// 只由 ASCII 十进制数字组成的正整数；含符号、空白、非 ASCII 数字或溢出时为 nil。
    ///
    /// 评论里的 MID、av 号与分 P 序号共用这一判定。
    package init?(positiveDecimal text: some StringProtocol) {
        guard !text.isEmpty,
            text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let value = Int64(text), value > 0
        else { return nil }
        self = value
    }
}

/// 请求评论图片时希望图片缩进的像素框；不带框表示请求原图。
public struct CommentAssetPixelBox: Sendable, Equatable, Hashable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// 资源的进程内不透明引用；远端 URL 只由具体 adapter 解析和消费。
public struct CommentAssetReference: Sendable, Equatable, Hashable {
    private enum Storage: Sendable, Equatable, Hashable {
        case opaque(UUID)
        case remote(URL)
    }

    private let storage: Storage

    package var remoteURL: URL? {
        guard case .remote(let url) = storage else { return nil }
        return url
    }

    public init() {
        storage = .opaque(UUID())
    }

    package init(remoteURL: URL) {
        storage = .remote(remoteURL)
    }
}

/// 外部 HTTPS 链接的进程内不透明引用。
public struct CommentExternalLinkReference: Sendable, Equatable, Hashable {
    private enum Storage: Sendable, Equatable, Hashable {
        case opaque(UUID)
        case remote(URL)
    }

    private let storage: Storage

    package var remoteURL: URL? {
        guard case .remote(let url) = storage else { return nil }
        return url
    }

    public init() {
        storage = .opaque(UUID())
    }

    package init(remoteURL: URL) {
        storage = .remote(remoteURL)
    }
}

public enum CommentAuthorSex: Sendable, Equatable, Hashable {
    case male
    case female
    case unspecified
}

public enum CommentVerification: Sendable, Equatable, Hashable {
    case personal(description: String?)
    case organization(description: String?)
}

public struct CommentAuthor: Sendable, Equatable, Hashable {
    public let id: CommentAuthorID
    public let name: String
    public let avatar: CommentAssetReference?
    public let sex: CommentAuthorSex
    public let level: Int?
    public let isHardcoreMember: Bool
    public let isVIP: Bool
    public let verification: CommentVerification?
    public let isUploader: Bool

    public init(
        id: CommentAuthorID,
        name: String,
        avatar: CommentAssetReference? = nil,
        sex: CommentAuthorSex = .unspecified,
        level: Int? = nil,
        isHardcoreMember: Bool = false,
        isVIP: Bool = false,
        verification: CommentVerification? = nil,
        isUploader: Bool = false
    ) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.sex = sex
        self.level = level
        self.isHardcoreMember = isHardcoreMember
        self.isVIP = isVIP
        self.verification = verification
        self.isUploader = isUploader
    }
}

/// UTF-16 索引范围，与 Foundation attributed string 和远端 span 对齐。
public struct CommentTextRange: Sendable, Equatable, Hashable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct CommentEmote: Sendable, Equatable, Hashable {
    public let text: String
    public let range: CommentTextRange
    public let asset: CommentAssetReference
    public let size: CommentEmoteSize

    public init(
        text: String,
        range: CommentTextRange,
        asset: CommentAssetReference,
        size: CommentEmoteSize = .unknown
    ) {
        self.text = text
        self.range = range
        self.asset = asset
        self.size = size
    }
}

public enum CommentEmoteSize: Sendable, Equatable, Hashable {
    case standard
    case large
    case unknown
}

public enum CommentLinkTarget: Sendable, Equatable, Hashable {
    /// 站内视频；`page` 是链接里的分 P 序号（从 1 开始），`startSeconds` 是链接里的起播秒数（`t=`），
    /// 没有时为 nil。
    case video(bvid: String, page: Int?, startSeconds: Int?)
    /// 正文里的时间戳；在当前视频正在播的分 P 里跳到该秒数。
    case timestamp(seconds: Int)
    /// 正文里 @ 的用户；只填 MID、昵称与头像，进入空间时与评论作者走同一入口。
    case member(CommentAuthor)
    /// 指向 UP 主空间的链接；只有 MID，名字与头像由空间层另行取得。
    case space(memberID: Int64)
    /// b23.tv 短链；点击后才解析出真正的去向，解析失败时按外链打开原短链。
    case shortLink(CommentExternalLinkReference)
    case external(CommentExternalLinkReference)
}

public struct CommentLink: Sendable, Equatable, Hashable {
    public let range: CommentTextRange
    public let target: CommentLinkTarget

    public init(range: CommentTextRange, target: CommentLinkTarget) {
        self.range = range
        self.target = target
    }
}

public struct CommentImage: Sendable, Equatable, Hashable {
    public let asset: CommentAssetReference
    public let position: Int?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        asset: CommentAssetReference,
        position: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.asset = asset
        self.position = position
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct CommentContent: Sendable, Equatable {
    public let message: String
    public let emotes: [CommentEmote]
    public let links: [CommentLink]
    public let pictures: [CommentImage]
    public let pictureCount: Int

    public init(
        message: String,
        emotes: [CommentEmote] = [],
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil
    ) {
        self.message = message
        self.emotes = emotes
        self.links = links
        self.pictures = pictures
        self.pictureCount = pictureCount ?? pictures.count
    }
}

public enum CommentVisibility: Sendable, Equatable, Hashable {
    case normal
    case folded
    case unknown(rawValue: Int)
}

public enum CommentUnavailableReason: Sendable, Equatable, Hashable {
    case deleted
    case folded
    case unavailable
    case unknown(rawValue: Int)
}

public enum CommentProvenance: Sendable, Equatable, Hashable {
    case adminPinned
    case uploaderPinned
    case hotList
    case highLikeExposure
    case uploaderLiked
}

public struct CommentDetails: Sendable, Equatable {
    public let author: CommentAuthor
    public let content: CommentContent
    public let createdAt: Date
    public let location: String?
    public let likeCount: Int64
    public let replyCount: Int
    public let visibility: CommentVisibility
    public let provenance: [CommentProvenance]

    public init(
        author: CommentAuthor,
        content: CommentContent,
        createdAt: Date,
        location: String? = nil,
        likeCount: Int64,
        replyCount: Int = 0,
        visibility: CommentVisibility = .normal,
        provenance: [CommentProvenance] = []
    ) {
        self.author = author
        self.content = content
        self.createdAt = createdAt
        self.location = location
        self.likeCount = likeCount
        self.replyCount = replyCount
        self.visibility = visibility
        self.provenance = provenance
    }
}

public enum CommentPayload: Sendable, Equatable {
    case available(CommentDetails)
    case unavailable(CommentUnavailableReason)
}

public struct Comment: Sendable, Equatable, Identifiable {
    public let id: CommentID
    public let rootID: CommentID?
    public let parentID: CommentID?
    public let payload: CommentPayload

    public init(
        id: CommentID,
        rootID: CommentID? = nil,
        parentID: CommentID? = nil,
        payload: CommentPayload
    ) {
        self.id = id
        self.rootID = rootID
        self.parentID = parentID
        self.payload = payload
    }
}

public struct CommentThread: Sendable, Equatable, Identifiable {
    public var id: CommentID { root.id }

    public let root: Comment
    public let replyPreview: [Comment]

    public init(root: Comment, replyPreview: [Comment] = []) {
        self.root = root
        self.replyPreview = replyPreview
    }
}
