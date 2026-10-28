import BiliModels
import BiliNetworking
import Foundation
import SwiftProtobuf

/// 把互动弹幕 protobuf（`/x/v2/dm/web/view`）解码为 `DanmakuCommands`，由 `BiliDanmakuRepository` 调用。
///
/// 调用前响应已在 `BiliAPIClient` 通过 Content-Type、非 JSON／HTML 与大小上限检查（见 SECURITY-MODEL §4）。
/// protobuf 本身解不开或条数超限时整份失败；单条互动弹幕的字段越界、类型不认识或 `extra` 不合规只跳过这一条，
/// 不连累其他条。只认 UP 主弹幕（`#UP#`）、评分（`#GRADE#`）、投票（`#VOTE#`）与关联视频（`#LINK#`），
/// 其余类型跳过。`extra` 里的远端地址只读关联视频的封面 `arc_pic`，须过 `BiliBFSImageURLPolicy`，不合规时
/// 卡片照常留下、只缺封面；跳转链接 `jump_url` 不读，打开只按校验过的 BV 号（见 SECURITY-MODEL §4）。
enum DanmakuCommandDecoder {
    /// 一个视频的互动弹幕条数上限，超出整份失败；实测热门视频不超过十几条。
    private static let maximumCommandCount = 200
    /// 一个视频最多留下的卡片数，按时间先后取前这么多张，其余跳过。
    ///
    /// 卡片图在主线程绘制、整组常驻，不计入弹幕纹理的字节上限；实测一个视频最多十几张，调大放宽异常数据下的
    /// 内存与主线程开销。
    static let maximumCardCount = 30
    /// 票数、参与人数的上限；超出视为数据异常，跳过这一条。
    ///
    /// 远端数值不能在相加或换算时溢出。
    private static let maximumCount = 1_000_000_000
    /// 单条 `extra` JSON 的字节上限，超出跳过这一条；实测不到 1 KB。
    private static let maximumExtraByteCount = 16 * 1_024
    /// 正文、评分标题、投票问题与选项的字符数上限，超出跳过这一条。
    private static let maximumTextLength = 256
    /// 卡片显示时长的范围（毫秒）与缺失或越界时的默认值；实测 5000～7000。
    private static let displayDurationRange = 1_000...60_000
    private static let defaultDisplayMilliseconds = 5_000
    /// 卡片位置缺失或越界时的默认值：网页上评分卡片的位置（水平居中、偏下）。
    private static let defaultPosition = DanmakuCardPosition(x: 0.5, y: 0.65)
    /// 投票选项数的范围，超出跳过这一条。
    private static let voteOptionCountRange = 1...10
    /// 评分的满分，平均分超出 0 到它的范围时跳过这一条。
    private static let maximumAverageScore = 10.0
    /// 当前账户评分（星数）的有效范围；0 表示没评过。
    private static let myScoreRange = 1...5
    /// 互动弹幕的 ID 前缀：与分段弹幕共用纹理与 layer 的 ID 空间，加前缀避免两边的 ID 碰巧相同。
    private static let idPrefix = "command:"

    static func commands(from data: Data) throws -> DanmakuCommands {
        let payload: Bilikit_Danmaku_ViewReply
        do {
            payload = try Bilikit_Danmaku_ViewReply(serializedBytes: data)
        } catch {
            throw BiliAPIError.invalidDanmakuData
        }
        guard payload.commandElements.count <= maximumCommandCount else {
            throw BiliAPIError.invalidDanmakuData
        }
        var uploaderEvents: [DanmakuEvent] = []
        var cards: [DanmakuCommandCard] = []
        for element in payload.commandElements {
            guard
                let id = DanmakuWireValues.identifier(
                    idString: element.idString,
                    numericID: element.id
                ),
                let time = DanmakuWireValues.seconds(fromMilliseconds: element.progressMilliseconds)
            else {
                continue
            }
            switch element.command {
            case "#UP#":
                if let event = uploaderEvent(
                    id: idPrefix + id,
                    time: time,
                    content: element.content
                ) {
                    uploaderEvents.append(event)
                }
            case "#GRADE#", "#VOTE#", "#LINK#":
                if cards.count < maximumCardCount,
                    let card = card(id: idPrefix + id, time: time, element: element)
                {
                    cards.append(card)
                }
            default:
                continue
            }
        }
        return DanmakuCommands(uploaderEvents: uploaderEvents, cards: cards)
    }

    /// UP 主弹幕按普通滚动弹幕显示：标准字号、白色；接口没有给出颜色与位置。
    private static func uploaderEvent(id: String, time: Double, content: String) -> DanmakuEvent? {
        guard let text = text(content) else { return nil }
        return DanmakuEvent(
            id: id,
            timeSeconds: time,
            mode: .scrolling,
            text: text,
            fontSize: DanmakuEvent.standardFontSize,
            colorRGB: 0xFF_FFFF,
            colorStyle: .solid,
            weight: 1,
            isHighLike: false,
            isUploader: true
        )
    }

    private static func card(
        id: String,
        time: Double,
        element: Bilikit_Danmaku_CommandElement
    ) -> DanmakuCommandCard? {
        let extraData = Data(element.extra.utf8)
        guard extraData.count <= maximumExtraByteCount,
            let extra = try? JSONDecoder().decode(CommandExtraPayload.self, from: extraData)
        else {
            return nil
        }
        let content: DanmakuCommandCard.Content
        switch element.command {
        case "#GRADE#":
            guard let grade = gradeCard(extra, fallbackTitle: element.content) else { return nil }
            content = .grade(grade)
        case "#VOTE#":
            guard let vote = voteCard(extra) else { return nil }
            content = .vote(vote)
        default:
            guard let link = linkCard(extra, fallbackTitle: element.content) else { return nil }
            content = .link(link)
        }
        let milliseconds =
            extra.duration.flatMap { displayDurationRange.contains($0) ? $0 : nil }
            ?? defaultDisplayMilliseconds
        return DanmakuCommandCard(
            id: id,
            timeSeconds: time,
            durationSeconds: Double(milliseconds) / 1_000,
            position: position(extra),
            content: content
        )
    }

    private static func gradeCard(
        _ extra: CommandExtraPayload,
        fallbackTitle: String
    ) -> DanmakuGradeCard? {
        guard let title = text(extra.msg ?? fallbackTitle),
            let average = extra.avgScore,
            average.isFinite,
            (0...maximumAverageScore).contains(average),
            let count = extra.count,
            (0...maximumCount).contains(count)
        else {
            return nil
        }
        return DanmakuGradeCard(
            title: title,
            averageScore: average,
            participantCount: count,
            myScore: extra.midScore.flatMap { myScoreRange.contains($0) ? $0 : nil }
        )
    }

    private static func voteCard(_ extra: CommandExtraPayload) -> DanmakuVoteCard? {
        guard let question = text(extra.question),
            let rawOptions = extra.options,
            voteOptionCountRange.contains(rawOptions.count),
            let total = extra.cnt,
            (0...maximumCount).contains(total)
        else {
            return nil
        }
        var options: [DanmakuVoteOption] = []
        var myOptionIndex: Int?
        for option in rawOptions {
            guard let text = text(option.desc),
                let count = option.cnt,
                (0...maximumCount).contains(count)
            else {
                return nil
            }
            // `my_vote` 是选项的 idx（从 1 起），0 表示没投过；对不上任何选项时当作没投过。
            if let myVote = extra.myVote, myVote > 0, option.idx == myVote {
                myOptionIndex = options.count
            }
            options.append(DanmakuVoteOption(text: text, voteCount: count))
        }
        return DanmakuVoteCard(
            question: question,
            options: options,
            participantCount: total,
            myOptionIndex: myOptionIndex
        )
    }

    /// 关联视频：BV 号不合法或没有标题时跳过；标题缺失时退回弹幕正文。
    private static func linkCard(
        _ extra: CommandExtraPayload,
        fallbackTitle: String
    ) -> DanmakuLinkCard? {
        guard let bvid = extra.bvid, BVID.isValid(bvid),
            let title = text(extra.title ?? fallbackTitle)
        else {
            return nil
        }
        // 封面是 `http:` 的图床地址，先按接口图片统一升级为 HTTPS，再要求落在 BFS 图床上。
        let coverURL = extra.arcPic
            .flatMap(WebImageURL.parse)
            .flatMap { BiliBFSImageURLPolicy.allows($0) ? $0 : nil }
        return DanmakuLinkCard(bvid: bvid, title: title, coverURL: coverURL)
    }

    /// `posX_2`／`posY_2` 是卡片中心在播放区里的百分比；缺失或越界时用默认位置。
    private static func position(_ extra: CommandExtraPayload) -> DanmakuCardPosition {
        guard let x = extra.posX2, let y = extra.posY2,
            x.isFinite, y.isFinite,
            (0...100).contains(x), (0...100).contains(y)
        else {
            return defaultPosition
        }
        return DanmakuCardPosition(x: x / 100, y: y / 100)
    }

    /// 去掉首尾空白；为空或超过长度上限时为 nil。
    private static func text(_ raw: String?) -> String? {
        guard let text = raw.flatMap(DanmakuWireValues.trimmedText),
            text.count <= maximumTextLength
        else {
            return nil
        }
        return text
    }
}

/// 评分、投票与关联视频 `extra` 里用到的字段；单个字段类型不对时按缺失处理，由调用方决定这一条是否成立。
private struct CommandExtraPayload: Decodable {
    struct Option: Decodable {
        let idx: Int?
        let desc: String?
        let cnt: Int?

        enum CodingKeys: String, CodingKey {
            case idx, desc, cnt
        }

        init(from decoder: any Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            idx = container.decodeLossyIfPresent(Int.self, forKey: .idx)
            desc = container.decodeLossyIfPresent(String.self, forKey: .desc)
            cnt = container.decodeLossyIfPresent(Int.self, forKey: .cnt)
        }
    }

    let duration: Int?
    let posX2: Double?
    let posY2: Double?
    let msg: String?
    let avgScore: Double?
    let count: Int?
    let midScore: Int?
    let question: String?
    let options: [Option]?
    let cnt: Int?
    let myVote: Int?
    let bvid: String?
    let title: String?
    let arcPic: String?

    enum CodingKeys: String, CodingKey {
        case duration, msg, count, question, options, cnt, bvid, title
        case posX2 = "posX_2"
        case posY2 = "posY_2"
        case avgScore = "avg_score"
        case midScore = "mid_score"
        case myVote = "my_vote"
        case arcPic = "arc_pic"
    }

    init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = container.decodeLossyIfPresent(Int.self, forKey: .duration)
        posX2 = container.decodeLossyIfPresent(Double.self, forKey: .posX2)
        posY2 = container.decodeLossyIfPresent(Double.self, forKey: .posY2)
        msg = container.decodeLossyIfPresent(String.self, forKey: .msg)
        avgScore = container.decodeLossyIfPresent(Double.self, forKey: .avgScore)
        count = container.decodeLossyIfPresent(Int.self, forKey: .count)
        midScore = container.decodeLossyIfPresent(Int.self, forKey: .midScore)
        question = container.decodeLossyIfPresent(String.self, forKey: .question)
        options = container.decodeLossyIfPresent([Option].self, forKey: .options)
        cnt = container.decodeLossyIfPresent(Int.self, forKey: .cnt)
        myVote = container.decodeLossyIfPresent(Int.self, forKey: .myVote)
        bvid = container.decodeLossyIfPresent(String.self, forKey: .bvid)
        title = container.decodeLossyIfPresent(String.self, forKey: .title)
        arcPic = container.decodeLossyIfPresent(String.self, forKey: .arcPic)
    }
}
