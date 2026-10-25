import Testing

@testable import BiliNetworking

/// 协议补全与 `http://` 升级只按字符串前缀改写：只有 `//` 补 `https:`，只有不分大小写的 `http://` 升级，
/// `http:` 无斜杠等写法原样留给调用方的来源校验。
struct RemoteURLStringTests {
    @Test(
        arguments: [
            ("//i0.hdslb.com/bfs/a.jpg", "https://i0.hdslb.com/bfs/a.jpg"),
            ("///i0.hdslb.com/bfs/a.jpg", "https:///i0.hdslb.com/bfs/a.jpg"),
            ("http://i0.hdslb.com/bfs/a.jpg", "http://i0.hdslb.com/bfs/a.jpg"),
            ("/bfs/a.jpg", "/bfs/a.jpg"),
            ("", "")
        ]
    )
    func protocolRelativeAddressesGainHTTPS(value: String, expected: String) {
        #expect(RemoteURLString.resolvingProtocolRelative(value) == expected)
    }

    @Test(
        arguments: [
            ("http://i0.hdslb.com/a.jpg", "https://i0.hdslb.com/a.jpg", true),
            ("HTTP://i0.hdslb.com/a.jpg", "https://i0.hdslb.com/a.jpg", true),
            ("HtTp://b23.tv/abc", "https://b23.tv/abc", true),
            ("http:i0.hdslb.com/a.jpg", "http:i0.hdslb.com/a.jpg", false),
            ("http:/i0.hdslb.com/a.jpg", "http:/i0.hdslb.com/a.jpg", false),
            ("https://i0.hdslb.com/a.jpg", "https://i0.hdslb.com/a.jpg", false),
            ("//i0.hdslb.com/a.jpg", "//i0.hdslb.com/a.jpg", false),
            ("///i0.hdslb.com/a.jpg", "///i0.hdslb.com/a.jpg", false)
        ]
    )
    func onlyHTTPWithSlashesIsUpgraded(value: String, expected: String, upgraded: Bool) {
        let result = RemoteURLString.upgradingInsecureHTTP(value)
        #expect(result.0 == expected)
        #expect(result.upgraded == upgraded)
    }
}
