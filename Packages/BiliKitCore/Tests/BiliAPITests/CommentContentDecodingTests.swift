import BiliApplication
import BiliModels
import BiliNetworking
import Foundation
import Testing

@testable import BiliAPI

/// 固定评论正文与作者的解码契约：头像、表情与图片归一为安全的 HTTPS 资源引用，
/// 链接、@ 与表情按 UTF-16 范围标注，损坏或有歧义的标注退回字面文本，图片超过九张拒绝。
@Suite("Comment content", .timeLimit(.minutes(1)))
struct CommentContentDecodingTests {
    @Test(
        arguments: [
            "//i0.hdslb.com/bfs/face/protocol-relative.jpg",
            "http://i1.hdslb.com/bfs/face/legacy-http.jpg",
            "https://i2.hdslb.com/bfs/face/secure.jpg"
        ]
    )
    func commentAvatarMapsToNormalizedOpaqueAssetReference(_ value: String) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mid": "42",
            "uname": "评论者",
            "avatar": value
        ])
        let payload = try JSONDecoder().decode(CommentMemberPayload.self, from: data)

        let avatar = try #require(payload.model(uploaderID: nil).avatar?.remoteURL)

        #expect(avatar.scheme == "https")
        #expect(avatar.user == nil)
        #expect(avatar.password == nil)
    }

    @Test
    func commentAvatarWithUserInfoDegradesWithoutDiscardingAuthor() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "mid": "42",
            "uname": "评论者",
            "avatar": "https://user@i0.hdslb.com/bfs/face/avatar.jpg"
        ])
        let payload = try JSONDecoder().decode(CommentMemberPayload.self, from: data)

        let author = try payload.model(uploaderID: nil)

        #expect(author.name == "评论者")
        #expect(author.avatar == nil)
    }

    @Test
    func commentLinksMapVideoExternalAndMemberTargetsWithUTF16Ranges() throws {
        let body = Data(
            #"""
            {
              "message": "看视频 访问活动 @回复用户",
              "jump_url": {
                "看视频": {
                  "pc_url": "https://www.bilibili.com/video/BV1FixtureA1?p=1"
                },
                "访问活动": {
                  "pc_url": "https://www.bilibili.com/opus/42#reply"
                }
              },
              "members": [
                { "mid": 301, "uname": "回复用户", "avatar": "https://i0.hdslb.com/bfs/face/fixture.jpg" }
              ],
              "pictures": []
            }
            """#.utf8
        )
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg"))
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        let links = try payload.model().links

        #expect(links.count == 3)
        #expect(
            links.map(\.range) == [
                CommentTextRange(location: 0, length: 3),
                CommentTextRange(location: 4, length: 4),
                CommentTextRange(location: 9, length: 5)
            ]
        )
        #expect(links[0].target == .video(bvid: "BV1FixtureA1", page: 1, startSeconds: nil))
        guard case .external(let externalReference) = links[1].target else {
            Issue.record("Expected an external comment link")
            return
        }
        #expect(
            externalReference.remoteURL.absoluteString
                == "https://www.bilibili.com/opus/42#reply"
        )
        // @ 用户带上昵称与头像，进入空间时空间头部才有名字和头像。
        #expect(
            links[2].target
                == .member(
                    CommentAuthor(
                        id: CommentAuthorID(rawValue: "301"),
                        name: "回复用户",
                        avatar: CommentAssetReference(remoteURL: avatarURL)
                    )
                )
        )
    }

    /// 非内部视频的合法 HTTPS jump_url 保持为外部链接；非 HTTPS 或带 userinfo 的直接丢弃。
    @Test(arguments: [
        ("https://www.bilibili.com/video/BV😈", true),
        ("https://example.com/video/BV1FixtureA1", true),
        ("https://www.bilibili.com/video/BV", true),
        ("http://www.bilibili.com/video/BV1FixtureA1", false),
        ("https://user@example.com/video/BV1FixtureA1", false)
    ])
    func commentJumpLinksKeepOnlySafeExternalHTTPS(
        value: String,
        isKept: Bool
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "message": "视频",
                "jump_url": ["视频": ["pc_url": value]]
            ]
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: data)

        let links = try payload.model().links

        guard isKept else {
            #expect(links.isEmpty)
            return
        }
        #expect(links.count == 1)
        guard case .external(let reference) = links.first?.target else {
            Issue.record("合法但非内部视频的 HTTPS jump_url 应保持为外部链接")
            return
        }
        #expect(reference.remoteURL == URL(string: value))
    }

    @Test
    func ambiguousDuplicateMentionNamesRemainLiteralText() throws {
        let body = Data(
            #"{"message":"@同名用户","members":[{"mid":301,"uname":"同名用户"},{"mid":302,"uname":"同名用户"}]}"#
                .utf8
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        #expect(try payload.model().links.isEmpty)
    }

    @Test
    func commentEmotesUsePerCommentAnnotationsAndUTF16Ranges() throws {
        let body = Data(
            #"""
            {
              "message": "前😺[doge]中[doge][大表情]",
              "emote": {
                "[doge]": {
                  "text": "[doge]",
                  "url": "http://i0.hdslb.com/bfs/emote/doge.png",
                  "meta": { "size": 1 }
                },
                "[大表情]": {
                  "text": "[大表情]",
                  "url": "https://i0.hdslb.com/bfs/emote/large.png",
                  "meta": { "size": 2 }
                },
                "[未使用]": {
                  "text": "[未使用]",
                  "url": "https://i0.hdslb.com/bfs/emote/unused.png",
                  "meta": { "size": 1 }
                }
              }
            }
            """#.utf8
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        let emotes = try payload.model().emotes

        #expect(emotes.count == 3)
        #expect(emotes.map(\.text) == ["[doge]", "[doge]", "[大表情]"])
        #expect(
            emotes.map(\.range) == [
                CommentTextRange(location: 3, length: 6),
                CommentTextRange(location: 10, length: 6),
                CommentTextRange(location: 16, length: 5)
            ]
        )
        #expect(emotes.map(\.size) == [.standard, .standard, .large])
        #expect(emotes[0].asset == emotes[1].asset)
        #expect(emotes[1].asset != emotes[2].asset)
        #expect(emotes[0].asset.remoteURL.scheme == "https")
    }

    @Test
    func malformedOrUnmatchedCommentEmotesDegradeToLiteralText() throws {
        let body = Data(
            #"""
            {
              "message": "[有效][错名][坏地址][未知尺寸]",
              "emote": {
                "[有效]": {
                  "url": "//i0.hdslb.com/bfs/emote/valid.png",
                  "meta": { "size": "unexpected" }
                },
                "[错名]": {
                  "text": "[另一个名字]",
                  "url": "https://i0.hdslb.com/bfs/emote/mismatch.png"
                },
                "[坏地址]": {
                  "url": "https://user@example.invalid/emote.png"
                },
                "[未知尺寸]": {
                  "url": "https://i0.hdslb.com/bfs/emote/unknown.png",
                  "meta": { "size": 99 }
                },
                "[未出现]": {
                  "url": "https://i0.hdslb.com/bfs/emote/absent.png"
                }
              }
            }
            """#.utf8
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        let content = try payload.model()

        #expect(content.message == "[有效][错名][坏地址][未知尺寸]")
        #expect(content.emotes.map(\.text) == ["[有效]", "[未知尺寸]"])
        #expect(content.emotes.map(\.size) == [.unknown, .unknown])
    }

    @Test
    func overlappingEmotesPreferLongestAndSharedURLsShareAssetIdentity() throws {
        let body = Data(
            #"""
            {
              "message": "[doge][甲][乙]",
              "emote": {
                "[doge]": {
                  "url": "https://i0.hdslb.com/bfs/emote/doge.png"
                },
                "doge": {
                  "url": "https://i0.hdslb.com/bfs/emote/overlap.png"
                },
                "[甲]": {
                  "url": "https://i0.hdslb.com/bfs/emote/shared.png"
                },
                "[乙]": {
                  "url": "https://i0.hdslb.com/bfs/emote/shared.png"
                }
              }
            }
            """#.utf8
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        let emotes = try payload.model().emotes

        #expect(emotes.map(\.text) == ["[doge]", "[甲]", "[乙]"])
        #expect(emotes.first?.range == CommentTextRange(location: 0, length: 6))
        #expect(emotes[1].asset == emotes[2].asset)
        #expect(emotes[0].asset != emotes[1].asset)
    }

    @Test
    func commentPicturesMapWithinNineAndRejectOverflow() throws {
        let picture =
            #"{"img_src":"http://i0.hdslb.com/bfs/new_dyn/fixture.jpg","img_width":1920,"img_height":1080}"#
        let onePicturePayload = try JSONDecoder().decode(
            CommentContentPayload.self,
            from: Data(
                "{\"message\":\"fixture\",\"pictures\":[\(picture)]}".utf8
            )
        )
        let onePictureContent = try onePicturePayload.model()
        #expect(onePictureContent.pictureCount == 1)
        let mapped = try #require(onePictureContent.pictures.first)
        #expect(mapped.asset.remoteURL.scheme == "https")
        #expect(mapped.position == 0)
        #expect(mapped.pixelWidth == 1920)
        #expect(mapped.pixelHeight == 1080)

        let pictures = Array(repeating: picture, count: 10).joined(separator: ",")
        let body = Data(
            "{\"message\":\"fixture\",\"pictures\":[\(pictures)]}".utf8
        )
        let payload = try JSONDecoder().decode(
            CommentContentPayload.self,
            from: body
        )

        #expect(throws: BiliAPIError.self) {
            try payload.model()
        }
    }

    @Test
    func malformedCommentPicturesKeepStableSlotsAndDegradeLocally() throws {
        let body = Data(
            #"{"message":"fixture","pictures":[42,{"img_src":"https://user@i0.hdslb.com/bfs/new_dyn/rejected.webp"},{"img_src":"//i1.hdslb.com/bfs/new_dyn/valid.webp","img_width":-1,"img_height":0}]}"#
                .utf8
        )
        let payload = try JSONDecoder().decode(CommentContentPayload.self, from: body)

        let content = try payload.model()

        #expect(content.pictureCount == 3)
        #expect(content.pictures.count == 1)
        #expect(content.pictures[0].position == 2)
        #expect(content.pictures[0].pixelWidth == nil)
        #expect(content.pictures[0].pixelHeight == nil)
    }
}
