import BiliApplication
import BiliVideoDetailFeature

/// 播放器快捷键 Q（点赞）、长按 Q（三连）、W（投币）、E（收藏）的意图：执行并返回要在播放器上显示的提示。
///
/// 由 `WindowComposition` 用窗口的写入协调者与播放页互动状态构造（`make`），经播放器内容一路交给
/// `NativePlayerHostView` 的键盘 controller。门槛与写入都在协调者里，这里只决定按键当下给什么提示：没有可写入的
/// 账户时提示登录，互动状态还没读到时提示暂时不可用；全屏（AVKit 独立全屏窗口）下投币与收藏的面板在主窗口里看不到，
/// 只提示先退出全屏。不持有状态。
struct PlayerEngagementShortcuts {
    let toggleLike: @MainActor () -> PlayerEngagementFeedback?
    let triple: @MainActor () -> PlayerEngagementFeedback?
    let openCoinPanel: @MainActor (_ isFullScreen: Bool) -> PlayerEngagementFeedback?
    let chooseFavoriteFolders: @MainActor (_ isFullScreen: Bool) -> PlayerEngagementFeedback?

    @MainActor
    static func make(
        accountWrites: AccountWriteCoordinator,
        engagementModel: VideoEngagementModel
    ) -> Self {
        /// 门槛满足且读到了正在播放的视频的互动状态时给出 BVID 与状态，否则给出提示。
        func target() -> Target {
            guard accountWrites.isWritable else { return .blocked(.signInRequired) }
            guard let bvid = engagementModel.bvid, let state = engagementModel.engagement else {
                return .blocked(.unavailable)
            }
            return .ready(bvid: bvid, isLiked: state.isLiked)
        }

        return Self(
            toggleLike: {
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, let isLiked):
                    accountWrites.setLiked(!isLiked, bvid: bvid)
                    return isLiked ? .unliked : .liked
                }
            },
            triple: {
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, _):
                    accountWrites.triple(bvid: bvid)
                    return .tripleRequested
                }
            },
            openCoinPanel: { isFullScreen in
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready:
                    guard !isFullScreen else { return .exitFullScreenToCoin }
                    engagementModel.isCoinPanelPresented = true
                    return nil
                }
            },
            chooseFavoriteFolders: { isFullScreen in
                switch target() {
                case .blocked(let feedback):
                    return feedback
                case .ready(let bvid, _):
                    guard !isFullScreen else { return .exitFullScreenToFavorite }
                    accountWrites.chooseFavoriteFolders(bvid: bvid)
                    return nil
                }
            }
        )
    }

    /// 按键当下能否执行：可以时给出视频与是否已赞，不能时给出提示。
    private enum Target {
        case ready(bvid: String, isLiked: Bool)
        case blocked(PlayerEngagementFeedback)
    }
}
