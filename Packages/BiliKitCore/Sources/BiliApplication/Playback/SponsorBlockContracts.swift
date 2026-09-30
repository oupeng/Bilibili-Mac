import BiliModels
import Foundation

/// SponsorBlock 仓库 Port 接口，定义在 BiliApplication 层
public protocol SponsorBlockRepositoryPort: Sendable {
    /// 获取指定 bvid 视频的 SponsorBlock 片段列表
    func fetchSegments(bvid: String, serverURL: String) async throws -> [SponsorSegment]
}
