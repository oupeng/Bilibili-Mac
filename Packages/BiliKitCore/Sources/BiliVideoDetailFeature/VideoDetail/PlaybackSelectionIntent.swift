/// 打开或切换一个视频的意图：来源页、相关推荐、选集与评论链接都以它进入播放。
///
/// App 的导航协调只比较与转交它（同一意图不重复打开）；怎样把它落到当前视频上（就地换分 P、原地跳转、重新加载）
/// 由 `VideoViewModel.select(_:)` 决定。
public struct PlaybackSelectionIntent: Hashable, Sendable {
    public let bvid: String
    /// 应用内显式选中的分 P。
    public let preferredCID: Int64?
    /// 外部链接（评论正文）给出的分 P 序号，从 1 开始；超出范围时按默认分 P 打开。
    public let preferredPageNumber: Int?
    /// 外部链接给出的起播秒数（`t=`）；超出分 P 时长时忽略。
    public let preferredStartSeconds: Int?

    public init(
        bvid: String,
        preferredCID: Int64? = nil,
        preferredPageNumber: Int? = nil,
        preferredStartSeconds: Int? = nil
    ) {
        self.bvid = bvid
        self.preferredCID = preferredCID
        self.preferredPageNumber = preferredPageNumber
        self.preferredStartSeconds = preferredStartSeconds
    }
}
