import BiliModels
import Foundation
import Testing

@testable import BiliAPI

@Suite("Comment remote links")
struct CommentRemoteLinkTests {
    /// 桌面版、手机版与裸域的视频地址都在应用内播放；av 号换算为 BV 号，分 P 只接受正整数。
    @Test(
        arguments: [
            ("https://www.bilibili.com/video/BV1FixtureA1", "BV1FixtureA1", nil),
            ("https://m.bilibili.com/video/BV1FixtureA1/", "BV1FixtureA1", nil),
            ("https://bilibili.com/video/BV1FixtureA1?p=3", "BV1FixtureA1", 3),
            ("//www.bilibili.com/video/av170001", "BV17x411w7KC", nil),
            ("https://WWW.bilibili.com/video/AV2/?p=2&t=30", "BV1xx411c7mD", 2),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=0", "BV1FixtureA1", nil),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=abc", "BV1FixtureA1", nil),
            ("https://www.bilibili.com/video/BV1FixtureA1?p=+3", "BV1FixtureA1", nil),
            (
                "https://www.bilibili.com/video/BV1FixtureA1?p=99999999999999999999",
                "BV1FixtureA1", nil
            )
        ] as [(String, String, Int?)]
    )
    func videoAddressesOpenInApp(value: String, bvid: String, page: Int?) {
        #expect(CommentRemoteLink.target(value) == .video(bvid: bvid, page: page))
    }

    @Test(
        arguments: [
            ("https://space.bilibili.com/123456", Int64(123456)),
            ("https://space.bilibili.com/123456/?spm_id_from=comment", 123456),
            ("https://space.bilibili.com/123456/video", 123456),
            ("https://space.bilibili.com/123456/upload/video", 123456),
            ("https://m.bilibili.com/space/42", 42)
        ] as [(String, Int64)]
    )
    func spaceAddressesOpenTheSpaceInApp(value: String, memberID: Int64) {
        #expect(CommentRemoteLink.target(value) == .space(memberID: memberID))
    }

    /// 不能确定站内目标的地址都按公开 HTTPS 外链处理。
    ///
    /// 包括形状不合法的视频号或 MID、编码过的分隔符、带端口或多余路径段的地址，以及空间里投稿列表
    /// 以外、应用内没有对应页面的子页面（合集、收藏夹、动态）。
    @Test(arguments: [
        "https://www.bilibili.com/video/av0",
        "https://www.bilibili.com/video%2FBV1FixtureA1",
        "https://www.bilibili.com:8443/video/BV1FixtureA1",
        "https://www.bilibili.com/video/BV1FixtureA1/extra",
        "https://space.bilibili.com/123456/channel/collectiondetail?sid=9",
        "https://space.bilibili.com/123456/favlist?fid=1",
        "https://space.bilibili.com/123456/dynamic",
        "https://m.bilibili.com/space/abc",
        "https://www.bilibili.com/video/av2251799813685248",
        "https://www.bilibili.com/video/av12x",
        "https://space.bilibili.com/0",
        "https://space.bilibili.com/abc",
        "https://search.bilibili.com/all?keyword=BV1FixtureA1"
    ])
    func malformedInternalAddressesStayExternal(value: String) {
        guard case .external(let reference) = CommentRemoteLink.target(value) else {
            Issue.record("形状不合法的站内地址应保持为外部链接")
            return
        }
        #expect(reference.remoteURL == URL(string: value))
    }

    /// 已知的 av／BV 对照；超出规则范围时不换算。
    @Test(
        arguments: [
            (Int64(2), "BV1xx411c7mD"),
            (170001, "BV17x411w7KC"),
            (111_298_867_365_120, "BV1L9Uoa9EUx")
        ] as [(Int64, String)]
    )
    func convertsKnownAIDs(aid: Int64, bvid: String) {
        #expect(BiliVideoAID.bvid(fromAID: aid) == bvid)
    }

    @Test(arguments: [Int64(0), -1, 1 << 51, .max])
    func rejectsAIDsOutsideTheConversionRange(_ aid: Int64) {
        #expect(BiliVideoAID.bvid(fromAID: aid) == nil)
    }

    /// 搜索词链接（标记为布尔或 0／1）与没有网页地址的条目不生成链接，正文按普通文字显示。
    @Test
    func wordSearchAndAddresslessJumpURLsStayPlainText() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "关键词 热词 网页 应用 视频",
                "jump_url": [
                    "关键词": [
                        "pc_url": "//search.bilibili.com/all?keyword=%E5%85%B3",
                        "extra": ["is_word_search": true]
                    ],
                    "热词": [
                        "pc_url": "//search.bilibili.com/all?keyword=%E7%83%AD",
                        "extra": ["is_word_search": 1]
                    ],
                    "网页": ["pc_url": "", "title": "网页链接"],
                    "应用": ["app_url_schema": "bilibili://video/170001"],
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1FixtureA1",
                        "extra": ["is_word_search": false]
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        #expect(links.map(\.target) == [.video(bvid: "BV1FixtureA1", page: nil)])
        #expect(links.map(\.range) == [CommentTextRange(location: 13, length: 2)])
    }

    /// `extra` 形状异常时按普通链接处理，不拖累整条 jump_url。
    @Test
    func malformedExtraKeepsTheLink() throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "视频",
                "jump_url": [
                    "视频": [
                        "pc_url": "https://www.bilibili.com/video/BV1FixtureA1",
                        "extra": "unexpected"
                    ]
                ]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        #expect(
            try payload.model().links.map(\.target) == [.video(bvid: "BV1FixtureA1", page: nil)]
        )
    }
}
