import Foundation

/// SponsorBlock 恰饭/赞助跳过片段模型
public struct SponsorSegment: Sendable, Equatable, Identifiable, Codable {
    public var id: String { uuid }

    public let uuid: String
    public let cid: String?
    public let category: String
    public let actionType: String?
    public let startTimeSeconds: Double
    public let endTimeSeconds: Double
    public let votes: Int?
    public let locked: Int?

    public init(
        uuid: String,
        cid: String? = nil,
        category: String,
        actionType: String? = nil,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        votes: Int? = nil,
        locked: Int? = nil
    ) {
        self.uuid = uuid
        self.cid = cid
        self.category = category
        self.actionType = actionType
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.votes = votes
        self.locked = locked
    }
}
