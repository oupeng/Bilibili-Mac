import Testing

@testable import BiliApplication

/// 固定广播契约：每个订阅者独立收到此后的事件，一个订阅者结束不影响其他订阅者，初始值只给新订阅者。
@MainActor
struct AsyncBroadcastTests {
    @Test(.timeLimit(.minutes(1)))
    func everySubscriberReceivesEachEvent() async {
        let broadcast = AsyncBroadcast<Int>()
        var first = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
        var second = broadcast.subscribe(startingWith: nil).makeAsyncIterator()

        broadcast.yield(1)

        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingOneSubscriberDoesNotEndTheOthers() async {
        let broadcast = AsyncBroadcast<Int>()
        let cancelled = broadcast.subscribe(startingWith: nil)
        var survivor = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
        let consumer = Task {
            for await _ in cancelled {}
        }

        consumer.cancel()
        await consumer.value
        broadcast.yield(2)

        #expect(await survivor.next() == 2)
        var late = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
        broadcast.yield(3)
        #expect(await survivor.next() == 3)
        #expect(await late.next() == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func initialValueGoesOnlyToTheNewSubscriber() async {
        let broadcast = AsyncBroadcast<Int>()
        var existing = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
        var joining = broadcast.subscribe(startingWith: 0).makeAsyncIterator()

        #expect(await joining.next() == 0)
        broadcast.yield(1)

        #expect(await existing.next() == 1)
        #expect(await joining.next() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func releasingTheOwnerFinishesEverySubscription() async {
        var first: AsyncStream<Int>.Iterator
        var second: AsyncStream<Int>.Iterator
        do {
            let broadcast = AsyncBroadcast<Int>()
            first = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
            second = broadcast.subscribe(startingWith: nil).makeAsyncIterator()
        }

        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }
}
