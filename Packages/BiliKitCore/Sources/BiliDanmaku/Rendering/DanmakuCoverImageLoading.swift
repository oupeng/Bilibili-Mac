import BiliModels
import CoreGraphics
import Foundation

/// 关联视频卡片取封面的 port：先同步查缓存，未命中再异步加载。
///
/// 实现是 App 的 `NativeVideoImagePipeline`（无凭据 session、来源与响应校验、有界缓存，见 SECURITY-MODEL §4）；
/// 本模块不接触网络。地址由 BiliAPI 解码时按 BFS 图床规则筛过，管线请求前还会再检查一次。
public protocol DanmakuCoverImageLoading: Sendable {
    /// 已解码缓存里的封面；未命中或管线已关闭时为 nil。
    func cachedDanmakuCover(for url: URL) -> CGImage?
    /// 加载并解码；失败、取消或管线已关闭时为 nil。
    func danmakuCover(for url: URL) async -> CGImage?
}

/// 此刻正在显示的一张关联视频卡片，与它在调用方给定 layer 坐标里的位置；由 renderer 的
/// `visibleLinkCards(displayTime:in:)` 给出，弹幕 overlay 据此命中点击与提供辅助功能元素。
public struct DanmakuVisibleLinkCard: Equatable {
    public let card: DanmakuLinkCard
    public let frame: CGRect
}
