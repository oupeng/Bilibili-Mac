import Foundation

/// 按字节成本有界的 LRU 弹幕纹理缓存，让文本、字号、颜色与 scale 都相同的弹幕复用已栅格化的像素。
///
/// 只由 `DanmakuTexturePreparationOwner` 在 MainActor 上访问，自身不加锁。
/// 已就绪待挂上的纹理也只存在这里，在挂上前被淘汰时 renderer 取不到像素，这条弹幕不挂上。
final class DanmakuTextureLRUCache {
    /// 缓存的单项与总字节上限；超过单项上限的纹理不入缓存。
    struct Limits: Sendable, Equatable {
        /// 单项上限等于栅格化器的 8 MiB 纹理上限；总量 32 MiB 至少能放下四个最大纹理，
        /// 也低于在屏纹理的 64 MiB 上限。
        ///
        /// 调大总量提高重复文本的命中率、已就绪纹理也更少在挂上前被淘汰，但常驻内存随之增加；
        /// 调小则更常重新栅格化。
        static let production = Limits(
            maximumItemCost: DanmakuTextureRasterizer.maximumTextureByteCost,
            maximumTotalCost: 32 * 1_024 * 1_024
        )

        let maximumItemCost: Int
        let maximumTotalCost: Int
    }

    /// LRU 双向链表的节点：`previous` 弱引用，避免相邻节点互相强引用成环；强引用来自 `entries` 与
    /// `next` 链。
    private final class Node {
        let key: DanmakuTextureCacheKey
        let payload: DanmakuTexturePayload
        weak var previous: Node?
        var next: Node?

        init(
            key: DanmakuTextureCacheKey,
            payload: DanmakuTexturePayload
        ) {
            self.key = key
            self.payload = payload
        }
    }

    let limits: Limits
    private(set) var totalCost = 0
    private var entries: [DanmakuTextureCacheKey: Node] = [:]
    private var mostRecentlyUsed: Node?
    private var leastRecentlyUsed: Node?

    init(limits: Limits = .production) {
        precondition(limits.maximumItemCost > 0)
        precondition(limits.maximumTotalCost >= limits.maximumItemCost)
        self.limits = limits
    }

    func value(
        for key: DanmakuTextureCacheKey
    ) -> DanmakuTexturePayload? {
        guard let node = entries[key] else { return nil }
        moveToFront(node)
        return node.payload
    }

    @discardableResult
    func insert(
        _ payload: DanmakuTexturePayload,
        for key: DanmakuTextureCacheKey
    ) -> Bool {
        guard payload.byteCost <= limits.maximumItemCost else { return false }
        if let existing = entries[key] {
            remove(existing)
        }
        while totalCost + payload.byteCost > limits.maximumTotalCost,
            let oldest = leastRecentlyUsed
        {
            remove(oldest)
        }
        guard totalCost + payload.byteCost <= limits.maximumTotalCost else {
            return false
        }
        let node = Node(key: key, payload: payload)
        entries[key] = node
        insertAtFront(node)
        totalCost += payload.byteCost
        return true
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        mostRecentlyUsed = nil
        leastRecentlyUsed = nil
        totalCost = 0
    }

    private func moveToFront(_ node: Node) {
        guard mostRecentlyUsed !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func remove(_ node: Node) {
        unlink(node)
        entries[node.key] = nil
        totalCost -= node.payload.byteCost
    }

    private func unlink(_ node: Node) {
        let previous = node.previous
        let next = node.next
        previous?.next = next
        next?.previous = previous
        if mostRecentlyUsed === node {
            mostRecentlyUsed = next
        }
        if leastRecentlyUsed === node {
            leastRecentlyUsed = previous
        }
        node.previous = nil
        node.next = nil
    }

    private func insertAtFront(_ node: Node) {
        node.previous = nil
        node.next = mostRecentlyUsed
        mostRecentlyUsed?.previous = node
        mostRecentlyUsed = node
        if leastRecentlyUsed == nil {
            leastRecentlyUsed = node
        }
    }
}
