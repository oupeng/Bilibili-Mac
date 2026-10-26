import Testing

@testable import BiliApplication

/// 固定有界 LRU 契约：淘汰只按最近使用顺序、从最久未用的开始，成本合计不超过上限，超过单项上限的值不进入也不挤掉已有条目。
@MainActor
struct CostBoundedLRUCacheTests {
    @Test
    func evictsLeastRecentlyUsedInDeterministicOrder() {
        let cache = CostBoundedLRUCache<String, Int>(
            limits: CostBoundedLRUCacheLimits(maximumItemCost: 1, maximumTotalCost: 3)
        )
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        #expect(cache.value(for: "a") == 1)

        cache.insert(4, for: "d")
        #expect(cache.value(for: "b") == nil)
        cache.insert(5, for: "e")
        #expect(cache.value(for: "c") == nil)

        #expect(cache.count == 3)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "d") == 4)
        #expect(cache.value(for: "e") == 5)
    }

    @Test
    func totalCostStaysWithinLimitAndEvictsAsManyAsNeeded() {
        let cache = CostBoundedLRUCache<String, Int>(
            limits: CostBoundedLRUCacheLimits(maximumItemCost: 60, maximumTotalCost: 100)
        )
        #expect(cache.insert(1, cost: 30, for: "a"))
        #expect(cache.insert(2, cost: 30, for: "b"))
        #expect(cache.insert(3, cost: 30, for: "c"))
        #expect(cache.totalCost == 90)

        #expect(cache.insert(4, cost: 60, for: "d"))
        #expect(cache.totalCost == 90)
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.value(for: "d") == 4)
    }

    @Test
    func oversizedValueIsRejectedWithoutTouchingExistingEntries() {
        let cache = CostBoundedLRUCache<String, Int>(
            limits: CostBoundedLRUCacheLimits(maximumItemCost: 50, maximumTotalCost: 100)
        )
        cache.insert(1, cost: 50, for: "a")
        cache.insert(2, cost: 50, for: "b")

        #expect(!cache.insert(3, cost: 51, for: "a"))
        #expect(!cache.insert(4, cost: 51, for: "c"))
        #expect(cache.totalCost == 100)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == 2)
        #expect(cache.value(for: "c") == nil)
    }

    @Test
    func replacingAKeyRecountsItsCostAndMarksItMostRecent() {
        let cache = CostBoundedLRUCache<String, Int>(
            limits: CostBoundedLRUCacheLimits(maximumItemCost: 50, maximumTotalCost: 100)
        )
        cache.insert(1, cost: 40, for: "a")
        cache.insert(2, cost: 40, for: "b")

        cache.insert(10, cost: 20, for: "a")
        #expect(cache.totalCost == 60)
        #expect(cache.count == 2)

        cache.insert(3, cost: 40, for: "c")
        #expect(cache.totalCost == 100)
        cache.insert(4, cost: 10, for: "d")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 10)
        #expect(cache.totalCost == 70)
    }

    @Test
    func removeAllClearsEntriesAndCost() {
        let cache = CostBoundedLRUCache<String, Int>(
            limits: CostBoundedLRUCacheLimits(maximumItemCost: 10, maximumTotalCost: 30)
        )
        cache.insert(1, cost: 10, for: "a")
        cache.insert(2, cost: 10, for: "b")

        cache.removeAll()

        #expect(cache.count == 0)
        #expect(cache.totalCost == 0)
        #expect(cache.value(for: "a") == nil)
        #expect(cache.insert(3, cost: 10, for: "c"))
        #expect(cache.value(for: "c") == 3)
    }
}
