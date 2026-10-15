import BiliModels
import Foundation

/// BilibiliSponsorBlock API 的响应 Data Transfer Object
public struct SponsorSegmentPayload: Decodable, Sendable {
    public let uuid: String
    public let cid: String?
    public let category: String
    public let actionType: String?
    public let segment: [Double]
    public let votes: Int?
    public let locked: Int?

    enum CodingKeys: String, CodingKey {
        case uuid = "UUID"
        case cid
        case category
        case actionType
        case segment
        case votes
        case locked
    }

    public func model() -> SponsorSegment? {
        guard segment.count >= 2 else { return nil }
        let start = segment[0]
        let end = segment[1]
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return SponsorSegment(
            uuid: uuid,
            cid: cid,
            category: category,
            actionType: actionType,
            startTimeSeconds: start,
            endTimeSeconds: end,
            votes: votes,
            locked: locked
        )
    }
}
