import BiliApplication
import BiliModels
import Foundation

/// 播放器动作菜单「拷贝链接」「在浏览器中打开」的视频网页地址：当前呈现的视频与分 P，加上此刻的播放位置。
///
/// 只读本模型的呈现状态与调用方给的时间线快照，不持有状态。
extension VideoViewModel {
    /// 当前呈现视频的网页地址；没有可操作的视频（`operableBVID`）、或正在换分 P 时为 nil。
    ///
    /// 换分 P 期间呈现的还是旧分 P，给出的地址会指向用户刚离开的那一个，所以不给。多 P 视频带 `p=`。`timeline` 属于当前呈现的分 P 时按 `PlaybackShareLinkPolicy` 决定带不带 `t=`，否则不带时间：
    /// 换分 P 期间播放器上可能还是旧 item 的位置。
    public func shareURL(timeline: PlaybackTimelineSnapshot) -> URL? {
        if case .loadingPage = state { return nil }
        guard let bvid = operableBVID, let context = presentedContext else { return nil }
        let page = context.selectedPage
        let startSeconds =
            timeline.identity == presentedPlaybackIdentity
                && presentedPlaybackIdentity?.cid == page.cid
            ? PlaybackShareLinkPolicy.startSeconds(
                positionSeconds: timeline.positionSeconds,
                durationSeconds: page.durationSeconds
            ) : nil
        return BVID.webPageURL(
            bvid,
            pageNumber: context.pages.count > 1 ? page.index : nil,
            startSeconds: startSeconds
        )
    }
}

/// 分享链接什么时候带时间。
enum PlaybackShareLinkPolicy {
    /// 播放位置在开头这么多秒内不带时间：刚开始播放时带一个 `t=2` 没有意义，对方从头看就好。
    static let leadingOmittedSeconds = 5
    /// 离片尾这么多秒内（含已播完）不带时间，免得对方打开就停在片尾。
    static let trailingOmittedSeconds = 5

    /// 链接的起播秒数（向下取整）；落在开头或片尾的留白里时为 nil。
    static func startSeconds(positionSeconds: Double, durationSeconds: Int) -> Int? {
        let seconds = Int(positionSeconds.rounded(.down))
        guard seconds >= leadingOmittedSeconds,
            durationSeconds <= 0 || seconds < durationSeconds - trailingOmittedSeconds
        else { return nil }
        return seconds
    }
}
