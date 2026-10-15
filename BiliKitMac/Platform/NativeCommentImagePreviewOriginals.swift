import CoreGraphics

/// 一次评论图片预览会话持有的已解码原图：当前一张与前后各一张。
///
/// 大原图（12MP 照片解码后约 44 MB）超过窗口共享缓存的单项上限，不进共享缓存；预览打开期间由这里
/// 持有，来回翻页不重新下载与解码。会话随预览关闭释放，关闭后再打开会重新下载。
@MainActor
final class NativeCommentImagePreviewOriginals {
    /// 当前图片前后各保留几张。
    static let retainedNeighborDistance = 1

    private struct Retained {
        let image: CGImage
        let animation: NativeAnimatedImage?
    }

    private var retained: [Int: Retained] = [:]
    private var selectedIndex: Int?

    /// 取第 `index` 张原图，并以它为当前图片、丢掉超出保留范围的原图。
    ///
    /// 已持有时直接返回（按内存命中，不淡入），否则调用 `load`，完成时仍在保留范围内才持有。
    func image(
        at index: Int,
        load: () async -> NativeVideoImageLoadResult?
    ) async -> NativeVideoImageLoadResult? {
        select(index)
        if let hit = retained[index] {
            return NativeVideoImageLoadResult(
                image: hit.image,
                origin: .memoryCache,
                animation: hit.animation
            )
        }
        guard let result = await load() else { return nil }
        if let selectedIndex, Self.isRetained(index, around: selectedIndex) {
            retained[index] = Retained(image: result.image, animation: result.animation)
        }
        return result
    }

    private func select(_ index: Int) {
        selectedIndex = index
        retained = retained.filter { Self.isRetained($0.key, around: index) }
    }

    private static func isRetained(_ index: Int, around selectedIndex: Int) -> Bool {
        abs(index - selectedIndex) <= retainedNeighborDistance
    }
}
