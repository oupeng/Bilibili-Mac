import BiliNetworking
import Foundation
import Synchronization
import Testing

@testable import BiliAPI

// WBI key 缓存的生命周期：这些测试显式排 nav，并断言 nav 的次数与位置。
extension BiliAPIClientTests {
    /// 同一个 UTC 日内（直到当天最后一秒）复用 key；`timestamp / 86_400` 变化后，
    /// 下一个签名请求先重新取 nav。
    @Test
    func wbiKeyIsRefetchedOnceTheUTCDayChanges() async throws {
        let dayStart: Int64 = 1_700_006_400
        let clock = FixtureClock(dayStart)
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
                try fixtureResponse("search"),
                try fixtureResponse("nav"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { clock.now }
        )

        _ = try await search(client, "macOS")
        clock.now = dayStart + 86_399
        _ = try await search(client, "Swift")
        clock.now = dayStart + 86_400
        _ = try await search(client, "macOS")

        #expect(
            transport.capturedRequests().map(\.url.path) == [
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type",
                "/x/web-interface/wbi/search/type",
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type"
            ]
        )
    }

    /// 认证会话失效时丢弃 key：即使仍在同一天，下一个签名请求也先重新取 nav。
    @Test
    func wbiKeyIsRefetchedAfterAuthenticatedSessionInvalidation() async throws {
        let transport = StubTransport(
            responses: [
                try fixtureResponse("nav"),
                try fixtureResponse("search"),
                try fixtureResponse("nav"),
                try fixtureResponse("search")
            ]
        )
        let client = BiliAPIClient(
            transport: transport,
            timestampProvider: { 1_700_000_000 }
        )

        _ = try await search(client)
        await client.invalidateAuthenticatedSession()
        _ = try await search(client)

        #expect(
            transport.capturedRequests().map(\.url.path) == [
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type",
                StubTransport.wbiNavPath,
                "/x/web-interface/wbi/search/type"
            ]
        )
    }
}

/// 测试内可推进的秒级时间戳。
private final class FixtureClock: Sendable {
    private let value: Mutex<Int64>

    init(_ value: Int64) {
        self.value = Mutex(value)
    }

    var now: Int64 {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}
