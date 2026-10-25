import Testing

@testable import BiliNetworking

/// 单次结果只交付第一个结果：无论结果先于还是晚于等待方到达，等待方都恰好恢复一次，之后的交付被忽略。
@Suite(.timeLimit(.minutes(1)))
struct OneShotResultTests {
    @Test
    func resultArrivingBeforeTheWaiterIsKeptAndLaterResultsAreIgnored() async throws {
        let result = OneShotResult<Int>()

        #expect(result.resolve(.success(1)))
        #expect(!result.resolve(.success(2)))

        #expect(try await result.value() == 1)
    }

    @Test
    func suspendedWaiterResumesOnceWithTheFirstResult() async throws {
        let result = OneShotResult<Int?>()
        async let value = result.value()

        // 两次交付都可能先于挂起到达；无论哪种顺序都只恢复一次且保留第一个结果。
        result.resolve(.success(nil))
        result.resolve(.success(3))

        #expect(try await value == nil)
    }
}
