import Foundation

/// 资料库条目（稍后再看）不能在 BiliKit 里播放的原因。
///
/// 只描述接口给出的事实，由 BiliAPI 的条目映射判定；卡片角标、占位标题与读屏文案只在 Library 的
/// `LibraryUnavailabilityFormatting`。充电专属不在这里：播放页自己处理完整播放、试看与提示。
public enum LibraryItemUnavailability: Sendable, Equatable {
    /// 已失效（稍后再看 `state < 0`）。
    case invalid
    /// 番剧、影视等 PGC 内容；`label` 是接口给的分类原文，空时为 nil。
    case pgc(label: String?)
    /// 课程（`is_pugv` 为真）。
    case course
}
