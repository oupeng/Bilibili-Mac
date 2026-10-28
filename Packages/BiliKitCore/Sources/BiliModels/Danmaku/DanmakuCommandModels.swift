import Foundation

/// 互动弹幕卡片在播放区上的位置：卡片中心占播放区宽、高的比例，都在 0...1。
///
/// 取自接口的 `posX_2`／`posY_2`（百分比）；卡片超出播放区时由 renderer 往里收。
public struct DanmakuCardPosition: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 评分互动弹幕的结果：只读，不提供打分。
public struct DanmakuGradeCard: Sendable, Equatable {
    public let title: String
    /// 平均分，0...10。
    public let averageScore: Double
    public let participantCount: Int
    /// 当前账户打过的分（1...5 颗星）；未登录或没打过时为 nil。
    public let myScore: Int?

    public init(title: String, averageScore: Double, participantCount: Int, myScore: Int?) {
        self.title = title
        self.averageScore = averageScore
        self.participantCount = participantCount
        self.myScore = myScore
    }
}

/// 投票互动弹幕的一个选项。
public struct DanmakuVoteOption: Sendable, Equatable {
    public let text: String
    public let voteCount: Int

    public init(text: String, voteCount: Int) {
        self.text = text
        self.voteCount = voteCount
    }
}

/// 投票互动弹幕的结果：只读，不提供投票。
public struct DanmakuVoteCard: Sendable, Equatable {
    public let question: String
    public let options: [DanmakuVoteOption]
    public let participantCount: Int
    /// 当前账户投的选项在 `options` 里的下标；未登录或没投过时为 nil。
    public let myOptionIndex: Int?

    public init(
        question: String,
        options: [DanmakuVoteOption],
        participantCount: Int,
        myOptionIndex: Int?
    ) {
        self.question = question
        self.options = options
        self.participantCount = participantCount
        self.myOptionIndex = myOptionIndex
    }
}

/// 关联视频互动弹幕：UP 主在自己视频里指向另一个视频的卡片，点击在应用内打开。
///
/// 只带打开所需的 BV 号与展示用的标题、封面；不带接口给的跳转链接，打开只按 `bvid` 走应用内导航
/// （见 SECURITY-MODEL §4）。
public struct DanmakuLinkCard: Sendable, Equatable {
    public let bvid: String
    public let title: String
    /// 已过 BFS 图床来源规则的封面；没有或不合规时为 nil，卡片照常显示，封面位置留占位底色。
    public let coverURL: URL?

    public init(bvid: String, title: String, coverURL: URL?) {
        self.bvid = bvid
        self.title = title
        self.coverURL = coverURL
    }
}

/// 一张互动弹幕卡片：在 `timeSeconds` 出现，显示 `durationSeconds` 后消失。
///
/// 由 BiliAPI 的 `DanmakuCommandDecoder` 从 `dm/web/view` 解码产生，弹幕会话交给呈现端，renderer 按媒体时间显示；
/// 卡片不占车道。描述不展示正文，见 SECURITY-MODEL §8。
public struct DanmakuCommandCard: Sendable, Equatable, Identifiable {
    public enum Content: Sendable, Equatable {
        case grade(DanmakuGradeCard)
        case vote(DanmakuVoteCard)
        case link(DanmakuLinkCard)
    }

    public let id: String
    public let timeSeconds: Double
    public let durationSeconds: Double
    public let position: DanmakuCardPosition
    public let content: Content

    public init(
        id: String,
        timeSeconds: Double,
        durationSeconds: Double,
        position: DanmakuCardPosition,
        content: Content
    ) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.durationSeconds = durationSeconds
        self.position = position
        self.content = content
    }
}

extension DanmakuCommandCard: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuCommandCard(redacted)" }
    public var debugDescription: String { description }
}

/// 一个视频的互动弹幕：并入滚动弹幕的 UP 主弹幕，与按时间显示的卡片。
///
/// 弹幕会话在进入视频时读取一次；UP 主弹幕（`isUploader` 为 true 的 `DanmakuEvent`）由会话按时间并入对应分段，
/// 卡片交给呈现端。
public struct DanmakuCommands: Sendable, Equatable {
    public static let empty = DanmakuCommands(uploaderEvents: [], cards: [])

    public let uploaderEvents: [DanmakuEvent]
    public let cards: [DanmakuCommandCard]

    public init(uploaderEvents: [DanmakuEvent], cards: [DanmakuCommandCard]) {
        self.uploaderEvents = uploaderEvents
        self.cards = cards
    }
}

/// 卡片内容的描述同样不展示标题、问题、选项正文与关联视频，见 SECURITY-MODEL §8。
extension DanmakuGradeCard: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuGradeCard(redacted)" }
    public var debugDescription: String { description }
}

extension DanmakuVoteCard: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuVoteCard(redacted)" }
    public var debugDescription: String { description }
}

extension DanmakuLinkCard: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuLinkCard(redacted)" }
    public var debugDescription: String { description }
}

extension DanmakuVoteOption: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuVoteOption(redacted)" }
    public var debugDescription: String { description }
}
