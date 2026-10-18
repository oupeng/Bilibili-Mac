import BiliApplication

extension VideoSearchOrder {
    /// 搜索排序在接口 `order` 参数里的取值。
    var apiValue: String {
        switch self {
        case .relevance: "totalrank"
        case .mostPlayed: "click"
        case .newest: "pubdate"
        case .mostDanmaku: "dm"
        case .mostFavorited: "stow"
        }
    }
}

extension VideoDurationFilter {
    /// 时长筛选在接口 `duration` 参数里的取值。
    var apiValue: String { String(rawValue) }
}
