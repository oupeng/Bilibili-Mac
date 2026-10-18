import BiliVideoDetailFeature
import CoreGraphics
import Foundation

/// 图片管线内存缓存的上界，按管线的用途给出；两处生产调用方各用一组。
struct NativeVideoImageCacheLimits: Sendable, Equatable {
    /// 单项成本不超过总成本上限的这一份额。
    ///
    /// 评论图片预览的原图解码后可达数十 MiB，不能一张就挤掉整个窗口的封面与头像。超出的不进共享缓存，由预览会话
    /// （`NativeCommentImagePreviewOriginals`）持有当前与前后各一张；关闭预览后再打开会重新下载。
    static let maximumEntryCostDivisor = 4

    /// 窗口内所有封面、头像与评论图片共用。
    ///
    /// 调大占用更多常驻内存，调小在网格来回滚动时要重新下载更多图片；见 SECURITY-MODEL §4。
    static let window = NativeVideoImageCacheLimits(
        countLimit: 160,
        costLimit: 64 * 1_024 * 1_024
    )
    /// 进程级 Now Playing 只显示当前一张封面，留少量余地给切换前后的封面。
    ///
    /// 成本上限的 1/4（2 MiB）同时是单张封面能进缓存的上限，超出的封面照常显示但不缓存。
    static let nowPlayingArtwork = NativeVideoImageCacheLimits(
        countLimit: 4,
        costLimit: 8 * 1_024 * 1_024
    )

    let countLimit: Int
    let costLimit: Int

    var maximumEntryCost: Int { costLimit / Self.maximumEntryCostDivisor }
}

/// 按最近使用淘汰的有界内存解码缓存，张数与成本两个上限同时生效。
///
/// 由 `NativeVideoImagePipeline` 放在自己的 `Mutex` 状态里访问，本身不加锁；没有磁盘缓存，
/// 内存压力时由管线整体清空（见 SECURITY-MODEL §4）。单项成本超过 `maximumEntryCost` 的不进缓存，
/// 交给调用方自己持有。
struct NativeVideoImageCache {
    /// 一项缓存：第一帧、可选的动图编码数据、计入总成本的字节数，以及最近访问序号。
    ///
    /// `recency` 取递增的 `clock`，命中与写入时更新；超限时淘汰序号最小的一项。
    private struct Entry {
        let image: CGImage
        let animation: NativeAnimatedImage?
        let cost: Int
        var recency: UInt64
    }

    let limits: NativeVideoImageCacheLimits
    private(set) var totalCost = 0
    private(set) var count = 0
    private var clock: UInt64 = 0
    private var entries: [NativeVideoImageKey: Entry] = [:]

    init(limits: NativeVideoImageCacheLimits) {
        self.limits = limits
    }

    mutating func image(for key: NativeVideoImageKey) -> CGImage? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.recency = clock
        entries[key] = entry
        return entry.image
    }

    func animation(for key: NativeVideoImageKey) -> NativeAnimatedImage? {
        entries[key]?.animation
    }

    /// 成本是第一帧的解码字节数加动图编码数据的字节数；超过单项上限的不缓存。
    mutating func insert(
        _ image: CGImage,
        animation: NativeAnimatedImage?,
        for key: NativeVideoImageKey
    ) {
        let cost = image.bytesPerRow * image.height + (animation?.data.count ?? 0)
        guard cost <= limits.maximumEntryCost, limits.countLimit > 0 else { return }
        if let old = entries.removeValue(forKey: key) {
            totalCost -= old.cost
        }
        clock &+= 1
        entries[key] = Entry(image: image, animation: animation, cost: cost, recency: clock)
        totalCost += cost
        trimToLimits()
        count = entries.count
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
        count = 0
    }

    private mutating func trimToLimits() {
        while entries.count > limits.countLimit || totalCost > limits.costLimit {
            guard let oldest = entries.min(by: { $0.value.recency < $1.value.recency }) else {
                break
            }
            totalCost -= oldest.value.cost
            entries.removeValue(forKey: oldest.key)
        }
    }
}
