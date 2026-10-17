import CoreGraphics
import Foundation

/// 卡片与网格取图的 port：先同步查缓存，未命中再异步加载。
///
/// 实现是 App 的 `NativeVideoImagePipeline`（无凭据 session、来源与响应校验、有界缓存，见
/// SECURITY-MODEL §4）；本模块不接触网络。同步查缓存让复用的卡片在配置当帧就显示已缓存的图，
/// 不先闪一下占位。
public protocol NativeVideoImageLoading: Sendable {
    /// 已解码缓存里的图；未命中或管线已关闭时为 nil。
    func cachedImage(for url: URL, kind: NativeVideoCardImageKind) -> CGImage?
    /// 加载并解码；失败、取消或管线已关闭时为 nil。
    func image(for url: URL, kind: NativeVideoCardImageKind) async -> NativeVideoCardImage?
}

/// 卡片上的图片用途；每种用途的解码尺寸与响应上限由实现方决定。
public enum NativeVideoCardImageKind: Hashable, Sendable {
    case cover
    case avatar
}

/// 一次取图的结果：解码后的图，以及它是否刚从网络到达、需要淡入。
public struct NativeVideoCardImage: Sendable {
    public let image: CGImage
    /// 刚从网络到达的图片淡入；内存缓存命中直接显示。
    public let fadesIn: Bool

    public init(image: CGImage, fadesIn: Bool) {
        self.image = image
        self.fadesIn = fadesIn
    }
}
