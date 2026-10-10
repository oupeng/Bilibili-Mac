/// 用户对象里的大会员状态；评论作者与 UP 主名片共用同一判定。
struct MemberVIPPayload: Decodable, Sendable {
    let status: Int?

    var isActive: Bool { status == 1 }

    private enum CodingKeys: String, CodingKey {
        case status = "vipStatus"
    }
}
