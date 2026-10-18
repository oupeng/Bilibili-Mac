import CoreGraphics
import Foundation

/// 热搜词小图标的取图 port：先同步查缓存，未命中再异步加载。
///
/// 实现是 App 的窗口图片管线（无凭据 session、来源与响应校验、有界缓存，见 SECURITY-MODEL §4、§6），
/// 本 target 不接触网络。卡片取图 port `NativeVideoImageLoading` 只分封面与头像，热搜图标是搜索起始页
/// 自己的用途，不放宽那个 port。
public protocol TrendingSearchIconLoading: Sendable {
    /// 已解码缓存里的图标；未命中或管线已关闭时为 nil。
    func cachedTrendingSearchIcon(for url: URL) -> CGImage?
    /// 加载并解码；失败、取消或管线已关闭时为 nil。
    func trendingSearchIcon(for url: URL) async -> CGImage?
}
