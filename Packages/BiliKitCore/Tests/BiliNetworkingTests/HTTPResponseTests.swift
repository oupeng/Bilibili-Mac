import Foundation
import Testing

@testable import BiliNetworking

/// 响应头按 HTTP 规则不区分大小写读取；JSON 判定要求 Content-Type 声明 JSON 且正文以对象（或允许时数组）开头。
struct HTTPResponseTests {
    @Test
    func headerLookupIgnoresCase() {
        let response = HTTPResponse(
            statusCode: 302,
            headers: ["location": "https://b23.tv/x", "Content-Type": "text/plain"],
            body: Data()
        )

        #expect(response.headerValue("Location") == "https://b23.tv/x")
        #expect(response.headerValue("CONTENT-TYPE") == "text/plain")
        #expect(response.headerValue("Set-Cookie") == nil)
    }

    @Test(
        arguments: [
            (["content-type": "application/json; charset=utf-8"], #" {"code":0}"#, false, true),
            (["Content-Type": "Application/JSON"], #"{"code":0}"#, false, true),
            (["Content-Type": "application/json"], "[1]", false, false),
            (["Content-Type": "application/json"], "[1]", true, true),
            (["Content-Type": "text/html"], #"{"code":0}"#, false, false),
            ([:], #"{"code":0}"#, false, false)
        ] as [([String: String], String, Bool, Bool)]
    )
    func jsonCheckReadsContentTypeInAnyCase(
        headers: [String: String],
        body: String,
        allowsArray: Bool,
        expected: Bool
    ) {
        let response = HTTPResponse(statusCode: 200, headers: headers, body: Data(body.utf8))
        #expect(response.looksLikeJSON(allowsTopLevelArray: allowsArray) == expected)
    }
}
