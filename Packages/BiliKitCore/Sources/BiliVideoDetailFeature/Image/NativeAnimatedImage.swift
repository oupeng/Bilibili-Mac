import Foundation

/// 动图的原始编码数据，由 `NativeAnimatedImagePlayback` 边解码边播放；不预先解出所有帧。
///
/// 跨 target 契约：只能由 App 图片管线构造——管线只为保留动图的用途（评论图片格子与预览）、且通过播放门槛
/// （帧数 ≤ 1000、每帧像素 ≤ 2048×2048，见 SECURITY-MODEL §4）的源图构造它，并与第一帧一起缓存；本 target
/// 不自行构造，播放端信任这道门槛逐帧解码。用引用类型：缓存命中返回同一个实例，播放端按身份判断是不是同一张
/// 动图，不比较数据字节。
public final class NativeAnimatedImage: Sendable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }
}
