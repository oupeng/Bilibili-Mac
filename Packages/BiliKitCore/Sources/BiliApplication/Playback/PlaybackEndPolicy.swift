/// 播放到结尾之后做什么：用户在播放器动作菜单里选的设备级偏好，所有窗口与视频共用。
///
/// 原始值写进 UserDefaults（见 SECURITY-MODEL §6），改名会让已存的选择回退默认。
public enum PlaybackEndBehavior: String, CaseIterable, Sendable {
    /// 停在结尾（B 站的说法是不循环）；默认值。
    case stop
    /// 从头再播当前分 P。
    case repeatOne

    public static let defaultValue = PlaybackEndBehavior.stop
}

/// 当前 item 播完时要做的事。
public enum PlaybackEndAction: Sendable, Equatable {
    case none
    case replay
}

/// 播完时按偏好与当前视频的访问状态决定动作；纯函数，不读播放器。
///
/// 充电视频的试看片段播完时一律停下：试看结束本身就是 `ended`，重播会把试看提示刚出现就清掉，
/// 用户以为是视频本身在循环（试看提示见 `PlaybackPreviewEndPolicy`）。
public enum PlaybackEndPolicy {
    public static func action(
        behavior: PlaybackEndBehavior,
        accessNotice: PlaybackAccessNotice?
    ) -> PlaybackEndAction {
        if case .upowerPreview = accessNotice { return .none }
        return switch behavior {
        case .stop: .none
        case .repeatOne: .replay
        }
    }
}
