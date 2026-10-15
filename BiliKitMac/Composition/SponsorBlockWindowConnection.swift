import AppKit
import BiliAPI
import BiliApplication
import BiliBrowseFeature
import BiliModels
import Foundation

@MainActor
struct SponsorBlockWindowConnection {
    let start: () -> Void
    let stop: () -> Void
}

extension SponsorBlockWindowConnection {
    /// 把窗口的 SponsorBlock 会话接到共享播放时间线与 AVPlayer 引擎。
    static func live(
        apiClient: BiliAPIClient,
        timeline: any PlaybackTimelineProviding,
        performSeek: @escaping @MainActor (Double) -> Void
    ) -> SponsorBlockWindowConnection {
        let session = SponsorBlockSession(
            timeline: timeline,
            fetchSegments: { bvid, cid in
                try await apiClient.sponsorSegments(for: bvid, cid: cid)
            },
            performSeek: performSeek
        )
        return SponsorBlockWindowConnection(
            start: {
                session.start()
            },
            stop: {
                session.stop()
            }
        )
    }
}
