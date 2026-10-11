import BiliModels
import Foundation
import Testing

@testable import BiliAPI

@Suite("Comment link resolver")
struct CommentLinkResolverTests {
    private let resolver = BiliCommentLinkResolver()

    @Test
    func resolvesPositiveMemberIDsToThePublicSpacePage() throws {
        let url = try #require(
            resolver.externalURL(
                for: .member(CommentAuthor(id: CommentAuthorID(rawValue: "123456"), name: "用户"))
            )
        )

        #expect(url.absoluteString == "https://space.bilibili.com/123456")
    }

    /// 空间链接只在没有空间功能时回退到网页，地址与 @ 成员相同。
    @Test
    func spaceLinksFallBackToTheSamePublicSpacePage() {
        #expect(
            resolver.externalURL(for: .space(memberID: 123456))?.absoluteString
                == "https://space.bilibili.com/123456"
        )
        #expect(resolver.externalURL(for: .space(memberID: 0)) == nil)
    }

    @Test(arguments: ["", "0", "-1", "abc", "１２３", "999999999999999999999999"])
    func rejectsInvalidMemberIDs(_ value: String) {
        #expect(
            resolver.externalURL(
                for: .member(CommentAuthor(id: CommentAuthorID(rawValue: value), name: "用户"))
            ) == nil
        )
    }

    @Test
    func preservesAUserInitiatedPublicHTTPSExternalURL() throws {
        let url = try #require(
            URL(string: "https://www.bilibili.com/opus/42?from=comment#reply")
        )
        let reference = CommentExternalLinkReference(remoteURL: url)

        #expect(resolver.externalURL(for: .external(reference)) == url)
    }

    @Test(
        arguments: [
            "http://www.bilibili.com/opus/42",
            "https://user@www.bilibili.com/opus/42",
            "https://localhost/opus/42",
            "https://localhost./opus/42",
            "https://host.local/opus/42",
            "https://host.local./opus/42",
            "https://home.arpa./opus/42",
            "https://127.0.0.1/opus/42",
            "https://[::1]/opus/42",
            "https://www.bilibili.com:444/opus/42"
        ]
    )
    func rejectsUnsafeExternalDestinations(_ value: String) throws {
        let url = try #require(URL(string: value))
        let reference = CommentExternalLinkReference(remoteURL: url)

        #expect(resolver.externalURL(for: .external(reference)) == nil)
    }

    @Test
    func leavesVideoLinksForInAppNavigation() {
        #expect(
            resolver.externalURL(for: .video(bvid: "BV1FixtureA1", page: nil)) == nil
        )
    }
}
