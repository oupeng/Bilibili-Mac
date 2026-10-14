import AppKit
import BiliApplication
import BiliBrowseFeature
import BiliModels
import BiliUI
import Foundation
import Testing

@testable import BiliKit

@Suite(.serialized, .timeLimit(.minutes(1)))
struct NativePlaybackSidebarTests {
    @Test
    @MainActor
    func snapshotKeepsStableSemanticSectionsAndRows() {
        let presentation = presentation(bvid: "BVCurrent")

        #expect(
            presentation.sections.map(\.id)
                == [.uploader, .summary, .selection, .comments]
        )
        #expect(
            presentation.itemIDs
                == [
                    .uploader(bvid: "BVCurrent"),
                    .summary(bvid: "BVCurrent"),
                    .selection(bvid: "BVCurrent"),
                    .commentsHeader(subject: nil),
                    .commentsState(subject: nil, kind: .idle)
                ]
        )
    }

    @Test
    @MainActor
    func summaryCollapsesOnlyOverflowingBodyToFiveLines() {
        let summary = String(
            repeating: "简介正文需要由 TextKit 精确换行，并在超过五行时才提供展开控制。",
            count: 8
        )
        let collapsed = NativePlaybackSummaryGeometry(summary: summary, width: 240, expanded: false)
        let expanded = NativePlaybackSummaryGeometry(summary: summary, width: 240, expanded: true)
        let short = NativePlaybackSummaryGeometry(
            summary: "不足五行的简介",
            width: 240,
            expanded: false
        )

        #expect(collapsed.overflows)
        #expect(collapsed.maximumLines == NativePlaybackSummaryGeometry.collapsedLineLimit)
        #expect(collapsed.toggleFrame.height > 0)
        #expect(expanded.maximumLines == nil)
        #expect(expanded.height > collapsed.height)
        #expect(!short.overflows)
        #expect(short.maximumLines == nil)
        #expect(short.toggleFrame.height == 0)
    }

    @Test
    @MainActor
    func uploaderSignatureStaysOneLineAtAnyWidth() {
        let long = VideoUploaderHeaderContent(
            owner: VideoOwner(
                id: 1,
                name: "UP 主",
                signature: String(repeating: "签名", count: 40)
            )
        )
        let short = VideoUploaderHeaderContent(
            owner: VideoOwner(id: 1, name: "UP 主", signature: "短签名")
        )
        let wide = NativePlaybackUploaderGeometry(content: long, width: 720)
        let narrow = NativePlaybackUploaderGeometry(content: long, width: 408)
        let shortNarrow = NativePlaybackUploaderGeometry(content: short, width: 408)

        // 长签名省略为一行，完整文字由悬停原地展开显示；高度不随宽度或长度变化。
        #expect(
            narrow.signatureTextFrame.height == NativePlaybackUploaderGeometry.signatureLineHeight
        )
        #expect(narrow.height == wide.height)
        #expect(narrow.height == shortNarrow.height)
        #expect(narrow.signatureTextFrame.maxX <= 408)
    }

    @Test
    @MainActor
    func uploaderNameCentersOnTheAvatarOnlyWithoutSignature() {
        let avatarCenter = NativePlaybackSidebarItemMeasurement.avatarSize / 2
        let withoutSignature = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: .loaded(UploaderProfile())
            ),
            width: 520
        )
        let withSignature = NativePlaybackUploaderGeometry(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主", signature: "签名")
            ),
            width: 520
        )

        #expect(withoutSignature.nameFrame.midY == avatarCenter)
        #expect(withSignature.nameFrame.minY == 0)
    }

    /// 名片加载完成前名字保持默认色，不会先粉后灰地闪一下；大会员同时告知 VoiceOver。
    @Test(
        arguments: [
            (VideoUploaderProfileState.loading, false),
            (.loaded(UploaderProfile(isVIP: false)), false),
            (.loaded(UploaderProfile(isVIP: true)), true)
        ]
    )
    @MainActor
    func uploaderNameColorOnlyReflectsLoadedVIPState(
        profileState: VideoUploaderProfileState,
        expectsVIP: Bool
    ) throws {
        let name = "测试 UP"
        let item = NativePlaybackSidebarUploaderItem()
        item.view.frame = NSRect(x: 0, y: 0, width: 408, height: 60)
        item.configure(
            content: VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: name),
                profileState: profileState
            ),
            imagePipeline: NativeVideoImagePipeline(),
            onOpenSpace: nil
        )

        let nameLabel = try #require(
            descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == name
            }
        )
        #expect(nameLabel.textColor == (expectsVIP ? .systemPink : .labelColor))
        #expect(
            nameLabel.accessibilityLabel()
                == (expectsVIP
                    ? AppStrings.localized("UP 主，\(name)，大会员")
                    : AppStrings.localized("UP 主，\(name)"))
        )
    }

    @Test
    @MainActor
    func browsingAnotherSectionKeepsPagesOnlyForTheSelectedEpisodeSection() {
        let collection = VideoCollection(
            id: 1,
            title: "合集",
            reportedEpisodeCount: 2,
            sections: [
                collectionSection(
                    id: 10,
                    title: "正片",
                    episodes: [
                        collectionEpisode(
                            sectionID: 10,
                            episodeID: 100,
                            bvid: "BVCurrent",
                            title: "第一集"
                        )
                    ]
                ),
                collectionSection(
                    id: 11,
                    title: "花絮",
                    episodes: [
                        collectionEpisode(
                            sectionID: 11,
                            episodeID: 101,
                            bvid: "BVOther",
                            title: "幕后花絮"
                        )
                    ]
                )
            ]
        )
        let projection = selectionProjection(
            context: context(bvid: "BVCurrent", collection: collection)
        )
        let selectedSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: projection.selectedEpisodeSectionID
        )
        let otherSectionHeight = NativePlaybackSidebarItemMeasurement.selection(
            projection,
            width: 328,
            browsedSectionID: collection.sections[1].id
        )

        #expect(projection.showsSectionPicker)
        #expect(
            projection.episodeSections.map { $0.episodes.map(\.title) }
                == [["第一集"], ["幕后花絮"]]
        )
        #expect(projection.selectedEpisodeSectionID == collection.sections[0].id)
        #expect(projection.showsPagePicker)
        #expect(otherSectionHeight < selectedSectionHeight)
    }

    @Test
    @MainActor
    func retainedFailedPageKeepsSelectionAvailableAsARecoveryPath() {
        let context = context(bvid: "BVCurrent")
        let failure = VideoLoadFailure.playback

        #expect(
            NativePlaybackSidebarOverlay.resolve(
                state: .failedPage(
                    context: context,
                    targetPage: context.pages[1],
                    failure: failure
                ),
                hasPresentedContent: true
            ) == .none
        )
    }

    @Test
    @MainActor
    func presentationReloadsOnlyTheStableRowWhoseContentChanged() throws {
        let original = presentation(bvid: "BVCurrent")
        let content = try #require(original.content)
        let updatedUploader = NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主", signature: "新签名")
                ),
                summary: content.summary,
                summaryLinks: content.summaryLinks,
                selection: content.selection,
                comments: content.comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        )
        let overlayOnly = NativePlaybackSidebarPresentation(
            content: content,
            overlay: .loading(label: "正在加载所选视频上下文")
        )

        #expect(
            updatedUploader.changedItemIDs(comparedTo: original)
                == [.uploader(bvid: content.bvid)]
        )
        #expect(overlayOnly.changedItemIDs(comparedTo: original).isEmpty)
    }

    /// 只有同一行原地从“名片加载中”变为结果时淡入；首次配置、复用与已加载后的变化照常立即生效。
    @Test
    @MainActor
    func onlyArrivingUploaderProfileFadesIn() {
        func content(_ state: VideoUploaderProfileState) -> VideoUploaderHeaderContent {
            VideoUploaderHeaderContent(
                owner: VideoOwner(id: 1, name: "UP 主"),
                profileState: state
            )
        }
        let loading = content(.loading)
        let loaded = content(.loaded(UploaderProfile(signature: "签名", isVIP: true)))
        let reloaded = content(.loaded(UploaderProfile(signature: "新签名")))

        #expect(NativePlaybackUploaderProfileReveal.fades(from: loading, to: loaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: nil, to: loaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: loaded, to: reloaded))
        #expect(!NativePlaybackUploaderProfileReveal.fades(from: loaded, to: loading))
    }

    /// 过渡只覆盖 UP 主行的前提：名片各状态下行高相同，下方行不会位移。
    @Test(
        arguments: [
            VideoUploaderProfileState.loaded(UploaderProfile()),
            .loaded(UploaderProfile(signature: String(repeating: "签名", count: 40)))
        ]
    )
    @MainActor
    func uploaderRowKeepsItsHeightWhenProfileArrives(loaded: VideoUploaderProfileState) {
        func height(_ state: VideoUploaderProfileState) -> CGFloat {
            NativePlaybackUploaderGeometry(
                content: VideoUploaderHeaderContent(
                    owner: VideoOwner(id: 1, name: "UP 主"),
                    profileState: state
                ),
                width: 408
            ).height
        }

        #expect(height(.loading) == height(loaded))
    }

    /// 认证优先于大会员，个人与机构认证分开，普通用户没有角标。
    @Test(
        arguments: [
            (.personal(description: nil), false, .personalVerification),
            (.personal(description: nil), true, .personalVerification),
            (.organization(description: nil), true, .organizationVerification),
            (nil, true, .vip),
            (nil, false, nil)
        ] as [(CommentVerification?, Bool, NativeCommentAvatarMark?)]
    )
    func commentAvatarMarkPrefersVerificationOverVIP(
        verification: CommentVerification?,
        isVIP: Bool,
        expected: NativeCommentAvatarMark?
    ) {
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "昵称",
            isVIP: isVIP,
            verification: verification
        )

        #expect(NativeCommentAvatarMark(author: author) == expected)
    }

    /// 接口给了标题的链接：原文网址显示为「图标 + 标题」，图标与标题都带同一个链接；后面的链接位置
    /// 不受前面替换影响，没有标题的链接保持原文。
    @Test
    @MainActor
    func titledLinksShowIconAndTitleInPlaceOfTheAddress() throws {
        let short = "https://b23.tv/Jf3cvv2"
        let message = "看 \(short) 和 BV17x411w7KC"
        let source = message as NSString
        let shortRange = source.range(of: short)
        let bvidRange = source.range(of: "BV17x411w7KC")
        let iconURL = try #require(URL(string: "https://i0.hdslb.com/bfs/icon.png"))
        let content = CommentContent(
            message: message,
            links: [
                CommentLink(
                    range: CommentTextRange(
                        location: shortRange.location,
                        length: shortRange.length
                    ),
                    target: .shortLink(CommentExternalLinkReference()),
                    title: "韩语版《朋友的酒》",
                    icon: CommentAssetReference()
                ),
                CommentLink(
                    range: CommentTextRange(location: bvidRange.location, length: bvidRange.length),
                    target: .video(bvid: "BV17x411w7KC", page: nil, startSeconds: nil)
                )
            ]
        )
        let rendered = makeCommentTextRenderer(resolveURL: { _, _ in iconURL }).render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )
        let text = rendered.attributedString.string as NSString
        let titleRange = text.range(of: "韩语版《朋友的酒》")
        let iconLocation = titleRange.location - 1
        func link(at location: Int) -> String? {
            rendered.attributedString.attribute(.link, at: location, effectiveRange: nil) as? String
        }

        #expect(!rendered.attributedString.string.contains(short))
        #expect(titleRange.location != NSNotFound)
        #expect(
            rendered.attributedString.attribute(.attachment, at: iconLocation, effectiveRange: nil)
                is NSTextAttachment
        )
        #expect(link(at: iconLocation) == "bilikit-comment-link-0")
        #expect(link(at: titleRange.location) == "bilikit-comment-link-0")
        #expect(link(at: text.range(of: "BV17x411w7KC").location) == "bilikit-comment-link-1")
        #expect(rendered.pendingAssets.map(\.url) == [iconURL])
    }

    /// 图标地址不合规（解析不出）时只显示标题。
    @Test
    @MainActor
    func titledLinksWithoutAUsableIconShowOnlyTheTitle() {
        let content = CommentContent(
            message: "https://b23.tv/Jf3cvv2",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 0, length: 22),
                    target: .shortLink(CommentExternalLinkReference()),
                    title: "视频标题",
                    icon: CommentAssetReference()
                )
            ]
        )

        let rendered = makeCommentTextRenderer().render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )

        #expect(rendered.attributedString.string == "视频标题")
        #expect(rendered.pendingAssets.isEmpty)
        #expect(rendered.accessibilityText == "视频标题")
    }

    /// 图标在本作用域加载失败后重新渲染：只剩标题，不再登记加载；读屏文本读标题而不是网址。
    @Test
    @MainActor
    func failedLinkIconsFallBackToTheTitle() throws {
        let icon = CommentAssetReference()
        let iconURL = try #require(URL(string: "https://i0.hdslb.com/bfs/icon.png"))
        let content = CommentContent(
            message: "看 https://b23.tv/Jf3cvv2",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 2, length: 22),
                    target: .shortLink(CommentExternalLinkReference()),
                    title: "视频标题",
                    icon: icon
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 700_001),
            rootID: CommentID(rawValue: 1),
            revision: 1
        )
        let renderer = makeCommentTextRenderer(resolveURL: { _, _ in iconURL })
        renderer.retainFailureScopes([scope])
        #expect(renderer.render(content, scope: scope).pendingAssets.count == 1)

        #expect(renderer.markUnavailable(icon, in: scope))
        let rendered = renderer.render(content, scope: scope)

        #expect(rendered.attributedString.string == "看 视频标题")
        #expect(rendered.pendingAssets.isEmpty)
        #expect(rendered.accessibilityText == "看 视频标题")
    }

    /// 表情优先：与表情重叠的链接不替换成图标与标题，表情照常显示；读屏文本保留表情原文。
    @Test
    @MainActor
    func emotesWinOverOverlappingDecoratedLinks() throws {
        let emoteURL = try #require(URL(string: "https://i0.hdslb.com/bfs/emote.png"))
        let content = CommentContent(
            message: "[原神_哈哈]",
            emotes: [
                CommentEmote(
                    text: "[原神_哈哈]",
                    range: CommentTextRange(location: 0, length: 7),
                    asset: CommentAssetReference(),
                    size: .standard
                )
            ],
            links: [
                CommentLink(
                    range: CommentTextRange(location: 1, length: 2),
                    target: .video(bvid: "BV1xx411c7mD", page: nil, startSeconds: nil),
                    title: "游戏",
                    icon: CommentAssetReference()
                )
            ]
        )

        let rendered = makeCommentTextRenderer(resolveURL: { _, _ in emoteURL }).render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )

        #expect(rendered.attributedString.length == 1)
        #expect(
            rendered.attributedString.attribute(.attachment, at: 0, effectiveRange: nil)
                is NSTextAttachment
        )
        #expect(rendered.accessibilityText == "[原神_哈哈]")
    }

    /// 时间戳只在播放器已装好（有上限）且不超出当前分 P 时长时显示为链接。
    @Test
    @MainActor
    func timestampsLinkOnlyWithinTheCurrentPartDuration() {
        let content = CommentContent(
            message: "1:00 和 5:00",
            links: [
                CommentLink(
                    range: CommentTextRange(location: 0, length: 4),
                    target: .timestamp(seconds: 60)
                ),
                CommentLink(
                    range: CommentTextRange(location: 7, length: 4),
                    target: .timestamp(seconds: 300)
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 700_001),
            rootID: CommentID(rawValue: 1),
            revision: 1
        )
        let renderer = makeCommentTextRenderer()

        #expect(renderer.render(content, scope: scope).linkTargets.isEmpty)
        renderer.timestampLimitSeconds = 120
        #expect(renderer.render(content, scope: scope).linkTargets == [.timestamp(seconds: 60)])
        renderer.timestampLimitSeconds = 300
        #expect(renderer.render(content, scope: scope).linkTargets == [.timestamp(seconds: 60)])
    }

    /// 切换分 P 后上限变化：只有含时间戳链接的评论重新配置，链接随之更新；行高不变，更新方式与
    /// 正文修改相同。
    @Test
    @MainActor
    func timestampLimitChangeReconfiguresOnlyThreadsWithTimestamps() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let threads = [
            commentThread(
                id: 1,
                message: "1:00",
                links: [
                    CommentLink(
                        range: CommentTextRange(location: 0, length: 4),
                        target: .timestamp(seconds: 60)
                    )
                ]
            ),
            commentThread(id: 2, message: "第二条")
        ]
        let base = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(subject: subject, threads: threads)
        )
        func limited(_ seconds: Int?) throws -> NativePlaybackSidebarPresentation {
            let content = try #require(base.content)
            return NativePlaybackSidebarPresentation(
                content: NativePlaybackSidebarContent(
                    bvid: content.bvid,
                    uploader: content.uploader,
                    summary: content.summary,
                    summaryLinks: content.summaryLinks,
                    selection: content.selection,
                    comments: content.comments,
                    timestampLimitSeconds: seconds
                ),
                overlay: base.overlay
            )
        }
        let short = try limited(120)
        let long = try limited(600)

        let changed = long.changedItemIDs(comparedTo: short)

        #expect(changed == [.commentThread(subject: subject, rootID: CommentID(rawValue: 1))])
        #expect(try limited(120).changedItemIDs(comparedTo: short).isEmpty)
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: short.snapshotSections,
                next: long.snapshotSections,
                changedItemIDs: changed,
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
        )
    }

    /// 分 P 菜单项在标题为空时省略标题段，不出现「P1 ·  · 时长」。
    @Test
    @MainActor
    func pageMenuTitleOmitsAnEmptyPartTitle() {
        #expect(
            NativePlaybackSidebarSelectionItem.pageMenuTitle(
                index: 1,
                title: "第一部分",
                durationSeconds: 61
            ) == "P1 · 第一部分 · " + VideoDurationFormatting.string(seconds: 61)
        )
        #expect(
            NativePlaybackSidebarSelectionItem.pageMenuTitle(
                index: 2,
                title: " ",
                durationSeconds: 988
            ) == "P2 · " + VideoDurationFormatting.string(seconds: 988)
        )
    }

    /// 简介里有时间戳时，分 P 时长变化只重新配置简介这一项；没有时间戳的简介不受影响。
    @Test
    @MainActor
    func timestampLimitChangeReconfiguresSummaryOnlyWhenItHasTimestamps() throws {
        let base = try #require(presentation(bvid: "BVCurrent").content)
        let timestamp = CommentLink(
            range: CommentTextRange(location: 0, length: 4),
            target: .timestamp(seconds: 60)
        )
        func summary(
            links: [CommentLink],
            limit: Int?
        ) -> NativePlaybackSidebarPresentation {
            NativePlaybackSidebarPresentation(
                content: NativePlaybackSidebarContent(
                    bvid: base.bvid,
                    uploader: base.uploader,
                    summary: "1:00 开始",
                    summaryLinks: links,
                    selection: base.selection,
                    comments: base.comments,
                    timestampLimitSeconds: limit
                ),
                overlay: .none
            )
        }

        #expect(
            summary(links: [timestamp], limit: 600)
                .changedItemIDs(comparedTo: summary(links: [timestamp], limit: 120))
                == [.summary(bvid: "BVCurrent")]
        )
        #expect(
            summary(links: [], limit: 600)
                .changedItemIDs(comparedTo: summary(links: [], limit: 120)).isEmpty
        )
        #expect(
            summary(links: [timestamp], limit: 120)
                .changedItemIDs(comparedTo: summary(links: [], limit: 120))
                == [.summary(bvid: "BVCurrent")]
        )
    }

    /// 简介里的链接与评论正文同一套：点击交出目标；超出可跳转时长的时间戳不是链接。
    @Test
    @MainActor
    func summaryTextOpensLinksAndHidesUnreachableTimestamps() throws {
        let member = CommentAuthor(id: CommentAuthorID(rawValue: "20002"), name: "合作者")
        let text = "@合作者 2:00 9:00"
        let textView = NativePlaybackSidebarReadOnlyTextView(font: .systemFont(ofSize: 13))
        var opened: [CommentLinkTarget] = []
        textView.onOpenLink = { opened.append($0) }

        textView.setText(
            NativePlaybackSidebarLinkedText(
                text: text,
                links: [
                    CommentLink(
                        range: CommentTextRange(location: 0, length: 4),
                        target: .member(member)
                    ),
                    CommentLink(
                        range: CommentTextRange(location: 5, length: 4),
                        target: .timestamp(seconds: 120)
                    ),
                    CommentLink(
                        range: CommentTextRange(location: 10, length: 4),
                        target: .timestamp(seconds: 540)
                    )
                ],
                timestampLimitSeconds: 300
            ),
            font: .systemFont(ofSize: 13),
            color: .labelColor
        )
        let storage = try #require(textView.textStorage)
        for index in [0, 5, 10] {
            if let link = storage.attribute(.link, at: index, effectiveRange: nil) {
                _ = textView.textView(textView, clickedOnLink: link, at: index)
            }
        }

        #expect(storage.string == text)
        #expect(opened == [.member(member), .timestamp(seconds: 120)])
        #expect(storage.attribute(.link, at: 10, effectiveRange: nil) == nil)
    }

    @Test
    @MainActor
    func collectionUpdatePolicySeparatesStableRowsFromCommentAppend() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let original = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(subject: subject, threads: [first])
        )
        let changed = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(
                subject: subject,
                threads: [commentThread(id: 1, message: "修改后的正文")]
            )
        )
        let appended = presentation(
            bvid: "BVCurrent",
            comments: commentsPresentation(
                subject: subject,
                threads: [first, commentThread(id: 2, message: "第二条评论")]
            )
        )

        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: original.snapshotSections,
                changedItemIDs: [],
                hasSnapshotInFlight: false
            ) == .none
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: changed.snapshotSections,
                changedItemIDs: changed.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .reloadChangedItems
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: false
            ) == .appendComments
        )
        #expect(
            NativePlaybackSidebarCollectionUpdatePolicy.resolve(
                current: original.snapshotSections,
                next: appended.snapshotSections,
                changedItemIDs: appended.changedItemIDs(comparedTo: original),
                hasSnapshotInFlight: true
            ) == .replaceSnapshot
        )
    }

    /// 只隐藏焦点视图时 AppKit 会把焦点交给下一个 key view，也就是侧栏外的控件；
    /// 侧栏必须在隐藏前把焦点还给窗口。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func blockingOverlayReturnsHiddenSidebarFirstResponderToWindow(focus: SidebarFocus) {
        let (controller, window, outsideKeyView) = hostedSidebar()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)

        controller.update(
            presentation: NativePlaybackSidebarPresentation(
                content: presentation(bvid: "BVCurrent").content,
                overlay: .loading(label: "正在加载所选视频上下文")
            ),
            actions: actions
        )

        #expect(window.firstResponder === window)
        controller.tearDown()
        window.contentView = NSView()
    }

    /// 打开空间前侧栏先把焦点还给窗口：侧栏随后会被空间层盖住并隐藏，焦点留在其中会让系统在
    /// 空间层进场动画中途改派焦点，进场变成从中间宽度伸展。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func openingTheSpaceReturnsSidebarFirstResponderToWindowFirst(
        focus: SidebarFocus
    ) throws {
        let (controller, window, outsideKeyView) = hostedSidebar()
        var focusWhenOpening: [NSResponder?] = []
        var spaceActions = actions
        spaceActions.openUploaderSpace = { focusWhenOpening.append(window.firstResponder) }
        controller.update(presentation: presentation(bvid: "BVCurrent"), actions: spaceActions)
        controller.rootView.layoutSubtreeIfNeeded()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let uploaderItem = try #require(
            collectionView.visibleItems().lazy
                .compactMap { $0 as? NativePlaybackSidebarUploaderItem }.first
        )
        // UP 主行只有一个按钮，即名字右侧进入空间的箭头。
        let spaceButtons = descendants(of: uploaderItem.view).compactMap { $0 as? NSButton }
        #expect(spaceButtons.count == 1)
        let spaceButton = try #require(spaceButtons.first)
        #expect(!spaceButton.isHidden)
        #expect(spaceButton.accessibilityLabel() == AppStrings.localized("查看空间"))

        spaceButton.performClick(nil)

        #expect(focusWhenOpening.count == 1)
        #expect(focusWhenOpening.first.flatMap { $0 } === window)
        controller.tearDown()
        window.contentView = NSView()
    }

    /// 拆掉文档时 AppKit 会把窗口设回 first responder，但直接持有焦点的文本视图收不到
    /// resign（field editor 会随文本框结束编辑而 resign）；侧栏必须在拆文档前正常结束焦点。
    @Test(arguments: SidebarFocus.allCases)
    @MainActor
    func teardownResignsSidebarFirstResponderBeforeDetachingDocument(focus: SidebarFocus) {
        let (controller, window, outsideKeyView) = hostedSidebar()
        let focused = focusInsideSidebar(
            focus,
            of: controller,
            in: window,
            nextKeyView: outsideKeyView
        )
        #expect(focused != nil)
        #expect(window.firstResponder === focused)

        controller.tearDown()

        #expect(focused?.didResign == true)
        #expect(window.firstResponder === window)
        window.contentView = NSView()
    }

    @Test
    @MainActor
    func commentsUseStableSubjectAndRootIDsAcrossAppend() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = commentThread(id: 1, message: "第一条评论")
        let second = commentThread(id: 2, message: "第二条评论")
        let initial = commentsPresentation(subject: subject, threads: [first])
        let appended = commentsPresentation(subject: subject, threads: [first, second])

        #expect(
            commentItemIDs(initial)
                == [
                    .commentsHeader(subject: subject),
                    .commentThread(subject: subject, rootID: first.id),
                    .commentsFooter(subject: subject)
                ]
        )
        #expect(
            Array(commentItemIDs(appended).prefix(2)) == Array(commentItemIDs(initial).prefix(2))
        )
        #expect(
            commentItemIDs(appended)[2]
                == .commentThread(subject: subject, rootID: second.id)
        )
    }

    @Test
    @MainActor
    func commentRevisionTracksRenderedVerificationLinksAndPictures() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let message = "查看视频"
        let range = CommentTextRange(location: 0, length: 4)
        let plainAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者"
        )
        let verifiedAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            verification: .personal(description: "认证")
        )
        let avatarAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author"),
            name: "评论者",
            avatar: CommentAssetReference()
        )
        let plain = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: plainAuthor),
            replyState: nil
        )
        let verified = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: verifiedAuthor),
            replyState: nil
        )
        let avatar = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(id: 1, message: message, author: avatarAuthor),
            replyState: nil
        )
        let linked = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(
                        range: range,
                        target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                    )
                ],
                author: verifiedAuthor
            ),
            replyState: nil
        )
        let pictured = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 1,
                message: message,
                links: [
                    CommentLink(
                        range: range,
                        target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                    )
                ],
                pictures: [CommentImage(asset: CommentAssetReference())],
                author: verifiedAuthor
            ),
            replyState: nil
        )

        #expect(plain.revision != avatar.revision)
        #expect(plain.revision != verified.revision)
        #expect(verified.revision != linked.revision)
        #expect(linked.revision != pictured.revision)
    }

    @Test
    @MainActor
    func commentPaginationPreservesRowAnchorAtAndAboveTheOldBottom() async throws {
        let controller = NativePlaybackSidebarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let initial = commentsPresentation(
            subject: subject,
            threads: (1...60).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(bvid: "BVAnchor", comments: initial),
            actions: actions
        )
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let collectionLayout = try #require(collectionView.collectionViewLayout)
        let sidebarLayout = try #require(
            collectionLayout as? NativePlaybackSidebarLayout
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                collectionView.numberOfItems(inSection: 3) == 62
                    && collectionLayout.collectionViewContentSize.height > 600
                    && sidebarLayout.pendingRefinementIndexes.isEmpty
            }
        )
        let anchorPath = IndexPath(item: 31, section: 3)
        let initialAnchor = try #require(
            collectionLayout.layoutAttributesForItem(at: anchorPath)
        )
        controller.scroll(to: initialAnchor.frame.minY - 24)
        let relativeY =
            initialAnchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        let appended = commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(bvid: "BVAnchor", comments: appended),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 72,
                    sidebarLayout.pendingRefinementIndexes.isEmpty,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: anchorPath
                    )
                else { return false }
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - relativeY
                ) <= 1
            }
        )

        let previousHeight = collectionLayout.collectionViewContentSize.height
        controller.scroll(to: previousHeight)
        let previousMaximumY = max(
            0,
            previousHeight
                - controller.rootView.scrollView.documentVisibleRect.height
        )
        #expect(
            abs(
                controller.rootView.scrollView.documentVisibleRect.minY
                    - previousMaximumY
            ) <= 2
        )
        collectionView.layoutSubtreeIfNeeded()
        let bottomAnchorPath = try #require(
            collectionView.indexPathsForVisibleItems()
                .filter { $0.section == 3 && (1...70).contains($0.item) }
                .min { lhs, rhs in
                    let lhsY =
                        collectionLayout.layoutAttributesForItem(at: lhs)?
                        .frame.minY ?? .greatestFiniteMagnitude
                    let rhsY =
                        collectionLayout.layoutAttributesForItem(at: rhs)?
                        .frame.minY ?? .greatestFiniteMagnitude
                    return lhsY < rhsY
                }
        )
        let bottomAnchor = try #require(
            collectionLayout.layoutAttributesForItem(at: bottomAnchorPath)
        )
        let bottomRelativeY =
            bottomAnchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        let loadingAtBottom = commentsPresentation(
            subject: subject,
            threads: (1...70).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            },
            isLoadingNextPage: true
        )
        controller.update(
            presentation: presentation(
                bvid: "BVAnchor",
                comments: loadingAtBottom
            ),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 72,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: bottomAnchorPath
                    )
                else { return false }
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - bottomRelativeY
                ) <= 1
            }
        )

        let appendedAtBottom = commentsPresentation(
            subject: subject,
            threads: (1...80).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论")
            }
        )
        controller.update(
            presentation: presentation(
                bvid: "BVAnchor",
                comments: appendedAtBottom
            ),
            actions: actions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    collectionView.numberOfItems(inSection: 3) == 82,
                    sidebarLayout.pendingRefinementIndexes.isEmpty,
                    let preservedAnchor = collectionLayout.layoutAttributesForItem(
                        at: bottomAnchorPath
                    )
                else {
                    return false
                }
                let maximumY = max(
                    0,
                    collectionLayout.collectionViewContentSize.height
                        - controller.rootView.scrollView.documentVisibleRect.height
                )
                return abs(
                    preservedAnchor.frame.minY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        - bottomRelativeY
                ) <= 1
                    && maximumY
                        - controller.rootView.scrollView.documentVisibleRect.minY
                        > 40
            }
        )
        let appendedFooter = try #require(
            collectionLayout.layoutAttributesForItem(
                at: IndexPath(item: 81, section: 3)
            )
        )
        #expect(
            !appendedFooter.frame.intersects(
                controller.rootView.scrollView.documentVisibleRect
            )
        )
    }

    @Test
    @MainActor
    func aboveAnchorMutationAndContinuousResizeKeepTheSameCommentPosition() async throws {
        let controller = NativePlaybackSidebarController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer {
            controller.tearDown()
            window.contentView = nil
        }
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let initialThreads = (1...60).map {
            commentThread(id: Int64($0), message: "第 \($0) 条评论")
        }
        controller.update(
            presentation: presentation(
                bvid: "BVResizeAnchor",
                comments: commentsPresentation(
                    subject: subject,
                    threads: initialThreads
                )
            ),
            actions: actions
        )
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        let collectionLayout = try #require(collectionView.collectionViewLayout)
        let sidebarLayout = try #require(
            collectionLayout as? NativePlaybackSidebarLayout
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                collectionView.numberOfItems(inSection: 3) == 62
                    && collectionLayout.collectionViewContentSize.height > 600
                    && sidebarLayout.pendingRefinementIndexes.isEmpty
            }
        )
        let anchorPath = IndexPath(item: 31, section: 3)
        let anchor = try #require(
            collectionLayout.layoutAttributesForItem(at: anchorPath)
        )
        controller.scroll(to: anchor.frame.minY)
        let expectedRelativeY =
            anchor.frame.minY
            - controller.rootView.scrollView.documentVisibleRect.minY

        var mutatedThreads = initialThreads
        mutatedThreads[0] = commentThread(
            id: 1,
            message: String(repeating: "位于锚点上方的长评论正文", count: 20)
        )
        controller.update(
            presentation: presentation(
                bvid: "BVResizeAnchor",
                comments: commentsPresentation(
                    subject: subject,
                    threads: mutatedThreads
                )
            ),
            actions: actions
        )

        func anchorRelativeY() throws -> CGFloat {
            let attributes = try #require(
                collectionLayout.layoutAttributesForItem(at: anchorPath)
            )
            return attributes.frame.minY
                - controller.rootView.scrollView.documentVisibleRect.minY
        }
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                sidebarLayout.pendingRefinementIndexes.isEmpty
                    && (try? abs(anchorRelativeY() - expectedRelativeY) <= 1)
                        == true
            }
        )

        for width in [360.0, 520.0, 440.0] {
            window.setContentSize(NSSize(width: width, height: 600))
            window.contentView?.layoutSubtreeIfNeeded()
            let stabilized = await waitUntil(timeout: .seconds(5)) {
                sidebarLayout.pendingRefinementIndexes.isEmpty
                    && (try? abs(anchorRelativeY() - expectedRelativeY) <= 2)
                        == true
            }
            let currentRelativeY = try anchorRelativeY()
            let pendingCount = sidebarLayout.pendingRefinementIndexes.count
            #expect(
                stabilized,
                "width \(width), relativeY \(currentRelativeY), expected \(expectedRelativeY), pending \(pendingCount)"
            )
        }
    }

    /// 评论区已关闭是终态说明，不提供重试；其余失败仍显示可重试的失败状态。
    @Test
    @MainActor
    func closedCommentSectionShowsATerminalStateWithoutRetry() {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        for (error, kind) in [
            (CommentReadError.closed, NativePlaybackCommentsStateKind.closed),
            (.transportFailure, .failed)
        ] {
            let comments = NativePlaybackCommentsPresentation(
                subject: subject,
                sort: .hot,
                rootState: .failed(error),
                totalCount: 0,
                threads: []
            )
            #expect(
                presentation(bvid: "BVCurrent", comments: comments).itemIDs.last
                    == .commentsState(subject: subject, kind: kind)
            )
        }

        for (kind, offersRetry) in [
            (NativePlaybackCommentsStateKind.closed, false),
            (.failed, true)
        ] {
            let item = NativePlaybackCommentsStateItem()
            item.configure(kind: kind, onRetry: {})
            let visibleButtons = descendants(of: item.view)
                .compactMap { $0 as? NSButton }
                .filter { !$0.isHidden }
            #expect(visibleButtons.isEmpty != offersRetry)
        }
    }

    @Test
    @MainActor
    func commentLoadingAccessibilityDoesNotReuseStaleCountOrFooterState() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let loaded = commentsPresentation(
            subject: subject,
            threads: [commentThread(id: 1, message: "正文")]
        )
        let loading = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .latest,
            rootState: .loading,
            totalCount: 0,
            threads: []
        )
        let header = NativePlaybackCommentsHeaderItem()
        header.configure(presentation: loaded, onSelectSort: { _ in })
        let loadedCount = CommentPresentationFormatting.compactCount(
            loaded.totalCount
        )
        let countLabel = try #require(
            descendants(of: header.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == loadedCount }
        )
        #expect(countLabel.isAccessibilityElement())
        #expect(
            countLabel.accessibilityLabel()
                == AppStrings.localized("共 \(loadedCount) 条评论")
        )
        header.configure(presentation: loading, onSelectSort: { _ in })
        #expect(countLabel.stringValue.isEmpty)
        #expect(countLabel.accessibilityLabel() == nil)
        #expect(!countLabel.isAccessibilityElement())

        let footer = NativePlaybackCommentsFooterItem()
        footer.configure(footer: .loading, onRetry: {}, onLoadMore: {})
        #expect(footer.view.isAccessibilityElement())
        #expect(footer.view.accessibilityRole() == .staticText)
        #expect(
            footer.view.accessibilityLabel()
                == AppStrings.localized("后续评论加载中")
        )
        footer.configure(footer: .retry, onRetry: {}, onLoadMore: {})
        #expect(!footer.view.isAccessibilityElement())
        var loadMoreCount = 0
        footer.configure(
            footer: .loadMore,
            onRetry: {},
            onLoadMore: { loadMoreCount += 1 }
        )
        let loadMoreButton = try #require(
            descendants(of: footer.view).compactMap { $0 as? NSButton }
                .first {
                    !$0.isHidden && $0.title == AppStrings.localized("加载更多")
                }
        )
        loadMoreButton.performClick(nil)
        #expect(loadMoreCount == 1)
        footer.configure(
            footer: .end(memoryLimited: false),
            onRetry: {},
            onLoadMore: {}
        )
        #expect(!footer.view.isAccessibilityElement())
    }

    @Test
    @MainActor
    func commentsFooterOnlyClaimsAllCommentsForServerEnd() throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let stopped = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: 2,
            threads: [],
            paginationTermination: .duplicatePage
        )
        let ended = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: 2,
            threads: [],
            paginationTermination: .serverEnd,
            reachedEnd: true
        )

        #expect(stopped.footer == .stopped)
        #expect(ended.footer == .end(memoryLimited: false))
    }

    @Test
    @MainActor
    func commentRendererMapsLinkAttributesToTargetsAndSkipsInvalidRanges() {
        let message = "跳转 BV1FixtureA1 查看视频 @回复用户"
        let videoRange = (message as NSString).range(of: "BV1FixtureA1")
        let memberRange = (message as NSString).range(of: "@回复用户")
        let content = CommentContent(
            message: message,
            links: [
                CommentLink(
                    range: CommentTextRange(
                        location: videoRange.location,
                        length: videoRange.length
                    ),
                    target: .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
                ),
                CommentLink(
                    range: CommentTextRange(location: message.utf16.count, length: 4),
                    target: .video(bvid: "BV1OutOfRange", page: nil, startSeconds: nil)
                ),
                CommentLink(
                    range: CommentTextRange(
                        location: memberRange.location,
                        length: memberRange.length
                    ),
                    target: .member(
                        CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
                    )
                )
            ]
        )
        let rendered = makeCommentTextRenderer().render(
            content,
            scope: NativePlaybackCommentTextScope(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: 1),
                revision: 1
            )
        )
        func target(at location: Int) -> CommentLinkTarget? {
            guard
                let value = rendered.attributedString.attribute(
                    .link,
                    at: location,
                    effectiveRange: nil
                ) as? String,
                value.hasPrefix("bilikit-comment-link-"),
                let index = Int(value.dropFirst("bilikit-comment-link-".count)),
                rendered.linkTargets.indices.contains(index)
            else { return nil }
            return rendered.linkTargets[index]
        }

        #expect(
            rendered.linkTargets == [
                .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil),
                .member(CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户"))
            ]
        )
        #expect(
            target(at: videoRange.location)
                == .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil)
        )
        #expect(
            target(at: memberRange.location)
                == .member(CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户"))
        )
        #expect(target(at: 0) == nil)
    }

    @Test
    @MainActor
    func commentPictureLayoutMatchesTheBoundedOfficialWebFlow() {
        let portrait = CommentImage(
            asset: CommentAssetReference(),
            position: 0,
            pixelWidth: 270,
            pixelHeight: 360
        )
        let landscape = CommentImage(
            asset: CommentAssetReference(),
            position: 1,
            pixelWidth: 446,
            pixelHeight: 270
        )

        let layout = NativePlaybackCommentPictureLayout.make(
            images: [portrait, landscape],
            count: 2,
            availableWidth: 408
        )

        #expect(layout.size == CGSize(width: 364, height: 180))
        #expect(
            layout.frames == [
                CGRect(x: 0, y: 0, width: 135, height: 180),
                CGRect(x: 139, y: 0, width: 223, height: 135)
            ]
        )
    }

    @Test
    @MainActor
    func commentPicturesOpenAMetadataDrivenGalleryAndSkipStaleFocusRestore() throws {
        let first = CommentAssetReference()
        let third = CommentAssetReference()
        let pictures = [
            CommentImage(
                asset: first,
                position: 0,
                pixelWidth: 270,
                pixelHeight: 360
            ),
            CommentImage(
                asset: third,
                position: 2,
                pixelWidth: 446,
                pixelHeight: 270
            )
        ]
        let slots = NativePlaybackCommentPictureSlots.slots(
            images: pictures,
            count: 3
        )
        #expect(slots.map(\.reference) == [first, nil, third])
        #expect(slots.map(\.pixelWidth) == [270, nil, 446])
        #expect(slots.map(\.pixelHeight) == [360, nil, 270])

        let layout = NativePlaybackCommentPictureLayout.make(
            slots: slots,
            availableWidth: 408
        )
        #expect(layout.size == CGSize(width: 364, height: 319))
        #expect(layout.frames[0].size == CGSize(width: 135, height: 180))
        #expect(layout.frames[1].size == CGSize(width: 120, height: 120))
        #expect(layout.frames[2].origin == CGPoint(x: 0, y: 184))
        #expect(layout.frames[2].size == CGSize(width: 223, height: 135))

        let row = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 7,
                message: "带图评论",
                pictures: pictures,
                pictureCount: 3
            ),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        var openedGallery: NativePlaybackCommentPictureGallery?
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { openedGallery = $0 },
            onOpenAuthorSpace: nil
        )
        item.view.layoutSubtreeIfNeeded()

        let thirdPictureButton = try #require(
            descendants(of: item.view).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel()
                    == AppStrings.localized("查看第 \(3) 张评论图片")
            }
        )
        thirdPictureButton.performClick(nil)
        #expect(openedGallery?.references == [first, third])
        #expect(openedGallery?.selectedIndex == 1)

        let focusWindow = NSWindow(
            contentRect: item.view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let fallbackResponder = NSButton()
        item.view.addSubview(fallbackResponder)
        focusWindow.contentView = item.view
        let replacement = CommentAssetReference()
        let replacementRow = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 7,
                message: "已复用评论",
                pictures: [
                    CommentImage(
                        asset: replacement,
                        position: 2,
                        pixelWidth: 446,
                        pixelHeight: 270
                    )
                ],
                pictureCount: 3
            ),
            replyState: nil
        )
        item.configure(
            presentation: replacementRow,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { _ in },
            onOpenAuthorSpace: nil
        )
        item.view.layoutSubtreeIfNeeded()
        focusWindow.makeFirstResponder(fallbackResponder)

        openedGallery?.restoreFocus()

        #expect(focusWindow.firstResponder === fallbackResponder)

        item.releaseOffscreenResources()
        item.prepareForReuse()
        focusWindow.contentView = NSView()
    }

    @Test
    @MainActor
    func commentImagePreviewClampsSelectionAndNavigatesWithoutWrapping() {
        var selection = NativeCommentImagePreviewSelection(
            count: 3,
            requestedIndex: 9
        )
        #expect(selection.index == 2)
        #expect(selection.canSelectPrevious)
        #expect(!selection.canSelectNext)
        let didSelectPastEnd = selection.selectNext()
        let didSelectPrevious = selection.selectPrevious()
        #expect(!didSelectPastEnd)
        #expect(didSelectPrevious)
        #expect(selection.index == 1)

        selection = NativeCommentImagePreviewSelection(
            count: 3,
            requestedIndex: -4
        )
        #expect(selection.index == 0)
        #expect(!selection.canSelectPrevious)
        #expect(selection.canSelectNext)
    }

    @Test
    @MainActor
    func commentEmoteRendererUsesFixedTextKitAttachmentsAndLiteralFallback() throws {
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "前[doge]后",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 1, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )

        let rendered = renderer.render(content, scope: scope)
        let attachment = try #require(
            rendered.attributedString.attribute(
                .attachment,
                at: 1,
                effectiveRange: nil
            ) as? NSTextAttachment
        )

        #expect(rendered.attributedString.string == "前\u{fffc}后")
        #expect(attachment.bounds.size == NSSize(width: 18, height: 18))
        #expect(attachment.bounds.origin.y == NSFont.preferredFont(forTextStyle: .body).descender)
        #expect(!attachment.allowsTextAttachmentView)
        #expect(rendered.pendingAssets.map(\.reference) == [asset])

        renderer.retainFailureScopes([scope])
        #expect(renderer.markUnavailable(asset, in: scope))
        #expect(renderer.markUnavailable(asset, in: scope))
        let fallback = renderer.render(content, scope: scope)
        #expect(fallback.attributedString.string == content.message)
        #expect(fallback.pendingAssets.isEmpty)

        let otherScope = NativePlaybackCommentTextScope(
            subject: .video(aid: 2),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )
        #expect(renderer.render(content, scope: otherScope).pendingAssets.count == 1)
        renderer.retainFailureScopes([otherScope])
        #expect(renderer.render(content, scope: scope).pendingAssets.count == 1)
    }

    @Test
    @MainActor
    func commentEmoteFailureCacheIsBoundedByStableRenderScope() throws {
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "[doge]",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 0, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scopes = (0...512).map {
            NativePlaybackCommentTextScope(
                subject: .video(aid: 1),
                rootID: CommentID(rawValue: 10),
                revision: $0
            )
        }

        renderer.retainFailureScopes(Set(scopes))
        for scope in scopes {
            #expect(renderer.markUnavailable(asset, in: scope))
        }

        #expect(renderer.render(content, scope: scopes[0]).pendingAssets.count == 1)
        #expect(renderer.render(content, scope: scopes[512]).pendingAssets.isEmpty)
    }

    @Test
    @MainActor
    func lateCommentEmoteFailureCannotReenterAnInactiveScope() throws {
        let asset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/doge.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == asset ? url : nil
        }
        let content = CommentContent(
            message: "[doge]",
            emotes: [
                CommentEmote(
                    text: "[doge]",
                    range: CommentTextRange(location: 0, length: 6),
                    asset: asset,
                    size: .standard
                )
            ]
        )
        let scopeA = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 10),
            revision: 1
        )
        let scopeB = NativePlaybackCommentTextScope(
            subject: .video(aid: 2),
            rootID: CommentID(rawValue: 20),
            revision: 1
        )

        renderer.retainFailureScopes([scopeA])
        renderer.retainFailureScopes([scopeB])
        #expect(!renderer.markUnavailable(asset, in: scopeA))
        renderer.retainFailureScopes([scopeA])

        #expect(renderer.render(content, scope: scopeA).pendingAssets.count == 1)
    }

    @Test
    @MainActor
    func largeAndUnknownCommentEmotesKeepExplicitMeasurementSemantics() throws {
        let largeAsset = CommentAssetReference()
        let unknownAsset = CommentAssetReference()
        let url = try #require(
            URL(string: "https://i0.hdslb.com/bfs/emote/large.png")
        )
        let renderer = makeCommentTextRenderer { reference, _ in
            reference == largeAsset ? url : nil
        }
        let content = CommentContent(
            message: "[大][未知]",
            emotes: [
                CommentEmote(
                    text: "[大]",
                    range: CommentTextRange(location: 0, length: 3),
                    asset: largeAsset,
                    size: .large
                ),
                CommentEmote(
                    text: "[未知]",
                    range: CommentTextRange(location: 3, length: 4),
                    asset: unknownAsset,
                    size: .unknown
                )
            ]
        )
        let scope = NativePlaybackCommentTextScope(
            subject: .video(aid: 1),
            rootID: CommentID(rawValue: 11),
            revision: 1
        )

        let rendered = renderer.render(content, scope: scope)
        let attachment = try #require(
            rendered.attributedString.attribute(
                .attachment,
                at: 0,
                effectiveRange: nil
            ) as? NSTextAttachment
        )

        #expect(rendered.attributedString.string == "\u{fffc}[未知]")
        #expect(attachment.bounds.size == NSSize(width: 36, height: 36))
        #expect(attachment.bounds.origin.y == NSFont.preferredFont(forTextStyle: .body).descender)
        #expect(renderer.height(content, width: 200, scope: scope) >= 36)
    }

    @Test
    @MainActor
    func crowdedAuthorBadgesMergeHardcoreIntoLevelAndStatusBadgesStayOrdered() {
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "crowded-author"),
            name: "昵称应该完整显示",
            sex: .male,
            level: 6,
            isHardcoreMember: true,
            isVIP: true,
            isUploader: true
        )
        let statusBadges = NativePlaybackCommentProvenanceBadgesView()
        statusBadges.configure([.uploaderLiked, .uploaderPinned])

        #expect(
            NativePlaybackCommentAuthorBadgesView.segments(for: author).map(\.text)
                == ["♂", "LV6⚡︎", "UP"]
        )
        #expect(
            statusBadges.displayedTexts
                == [AppStrings.localized("置顶"), AppStrings.localized("UP 主觉得很赞")]
        )
        #expect(
            statusBadges.accessibilityLabel()
                == ListFormatter.localizedString(byJoining: statusBadges.displayedTexts)
        )
    }

    @Test(
        arguments: [
            (21, CommentAuthorSex.male, false),
            (22, CommentAuthorSex.female, false),
            (23, CommentAuthorSex.unspecified, true)
        ]
    )
    @MainActor
    func commentAuthorNameColorOnlyReflectsVIPState(
        id: Int,
        sex: CommentAuthorSex,
        isVIP: Bool
    ) throws {
        let expectedColor = isVIP ? NSColor.systemPink : NSColor.labelColor
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "author-\(id)"),
            name: "昵称\(id)",
            sex: sex,
            isVIP: isVIP
        )
        let row = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(id: Int64(id), message: "正文", author: author),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { _ in },
            onOpenAuthorSpace: nil
        )
        item.view.layoutSubtreeIfNeeded()

        let authorLabel = try #require(
            descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                $0.stringValue == author.name
            }
        )
        #expect(authorLabel.textColor == expectedColor)
    }

    /// 根评论与楼中楼回复的作者都提供“查看空间”，打开对应作者；MID 不合法的作者没有入口。
    @Test
    @MainActor
    func commentAuthorsOfferSpaceEntryOnlyForValidMemberIDs() throws {
        let rootAuthor = CommentAuthor(id: CommentAuthorID(rawValue: "1001"), name: "根评论作者")
        let replyAuthor = CommentAuthor(id: CommentAuthorID(rawValue: "1002"), name: "回复作者")
        let invalidAuthor = CommentAuthor(
            id: CommentAuthorID(rawValue: "author-x"),
            name: "无效作者"
        )
        let presentation = NativePlaybackCommentThreadPresentation(
            subject: .video(aid: 700_001),
            thread: commentThread(
                id: 31,
                message: "正文",
                replyCount: 2,
                preview: [
                    comment(id: 32, rootID: 31, message: "回复", author: replyAuthor),
                    comment(id: 33, rootID: 31, message: "回复", author: invalidAuthor)
                ],
                author: rootAuthor
            ),
            replyState: nil
        )
        var opened: [CommentAuthorID] = []
        let item = NativePlaybackCommentThreadItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(presentation, width: 408)
        )
        item.configure(
            presentation: presentation,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { _ in },
            onOpenAuthorSpace: { opened.append($0.id) }
        )
        item.view.layoutSubtreeIfNeeded()
        func spaceAction(for name: String) throws -> NSAccessibilityCustomAction? {
            let label = try #require(
                descendants(of: item.view).compactMap { $0 as? NSTextField }.first {
                    $0.stringValue == name
                }
            )
            return label.accessibilityCustomActions()?.first
        }

        let rootAction = try #require(try spaceAction(for: rootAuthor.name))
        #expect(rootAction.name == AppStrings.localized("查看空间"))
        #expect(rootAction.handler?() == true)
        #expect(try spaceAction(for: replyAuthor.name)?.handler?() == true)
        #expect(try spaceAction(for: invalidAuthor.name) == nil)
        #expect(opened == [rootAuthor.id, replyAuthor.id])
    }

    /// 进入空间的身份：正整数 MID、评论昵称，头像经评论资源解析器取得。
    @Test
    func commentAuthorSpaceOwnerUsesMemberIDAndResolvedAvatar() throws {
        let avatar = CommentAssetReference()
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/a.jpg"))
        let resolver: CommentAssetURLResolver = { reference, _ in
            reference == avatar ? avatarURL : nil
        }
        let author = CommentAuthor(
            id: CommentAuthorID(rawValue: "1001"),
            name: "评论作者",
            avatar: avatar
        )

        #expect(
            NativePlaybackCommentAuthorSpace.owner(for: author, resolveAvatar: resolver)
                == VideoOwner(id: 1001, name: "评论作者", avatarURL: avatarURL)
        )
        for rawValue in ["", "0", "-1", "author-x"] {
            let invalid = CommentAuthor(id: CommentAuthorID(rawValue: rawValue), name: "无效")
            #expect(!NativePlaybackCommentAuthorSpace.isOpenable(invalid))
            #expect(
                NativePlaybackCommentAuthorSpace.owner(for: invalid, resolveAvatar: resolver)
                    == nil
            )
        }
    }

    /// 正文 @ 提及在应用内打开空间；其他链接、以及没有空间入口时，交给原有处理。
    @Test
    func commentMentionLinksOpenTheSpaceInsideTheApp() {
        let mentioned = CommentAuthor(id: CommentAuthorID(rawValue: "301"), name: "回复用户")
        var openedSpaces: [CommentAuthor] = []
        var otherLinks: [CommentLinkTarget] = []
        func open(_ target: CommentLinkTarget, hasSpace: Bool) {
            NativePlaybackCommentAuthorSpace.openLink(
                target,
                openSpace: hasSpace ? { openedSpaces.append($0) } : nil,
                otherwise: { otherLinks.append($0) }
            )
        }

        open(.member(mentioned), hasSpace: true)
        open(.video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil), hasSpace: true)
        open(.member(mentioned), hasSpace: false)

        #expect(openedSpaces == [mentioned])
        #expect(
            otherLinks == [
                .video(bvid: "BV1FixtureA1", page: nil, startSeconds: nil), .member(mentioned)
            ]
        )
    }

    @Test(arguments: [2, 3])
    @MainActor
    func replySummaryRemainsAvailableWhenPreviewAlreadyShowsEveryReply(
        replyCount: Int
    ) throws {
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let previews = [
            comment(id: 31, rootID: 3, message: "回复一"),
            comment(id: 32, rootID: 3, message: "回复二")
        ]

        let row = NativePlaybackCommentThreadPresentation(
            subject: subject,
            thread: commentThread(
                id: 3,
                message: "正文",
                replyCount: replyCount,
                preview: previews
            ),
            replyState: nil
        )
        let item = NativePlaybackCommentThreadItem()
        item.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 408,
            height: NativePlaybackCommentsItemMeasurement.thread(row, width: 408)
        )
        item.configure(
            presentation: row,
            textRenderer: makeCommentTextRenderer(),
            avatarLoader: makeCommentAvatarLoader(),
            pictureLoader: makeCommentPictureLoader(),
            onTextLayoutChange: {},
            onExpand: {},
            onCollapse: {},
            onPrevious: {},
            onNext: {},
            onRetry: {},
            onOpenLink: { _ in },
            onOpenPictures: { _ in },
            onOpenAuthorSpace: nil
        )
        item.view.layoutSubtreeIfNeeded()

        let summary = descendants(of: item.view).compactMap { $0 as? NSButton }
            .first {
                $0.title
                    == AppStrings.localized(
                        "共 \(CommentPresentationFormatting.compactCount(replyCount)) 条回复"
                    )
            }
        #expect(summary != nil)
    }

    @Test
    @MainActor
    func commentHeightCacheIsBoundedAndUsesTrueLRURecency() {
        let cache = NativePlaybackSidebarHeightCache(capacity: 2)
        let first = heightKey(rootID: 1)
        let second = heightKey(rootID: 2)
        let third = heightKey(rootID: 3)

        cache.insert(101, for: first)
        cache.insert(102, for: second)
        #expect(cache.value(for: first) == 101)
        cache.insert(103, for: third)

        #expect(cache.count == 2)
        #expect(cache.value(for: first) == 101)
        #expect(cache.value(for: second) == nil)
        #expect(cache.value(for: third) == 103)
    }

    @Test
    @MainActor
    func resizeEstimatesImmediatelyAndRefinesAtMostThirtyTwoRowsPerBatch() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let entries = (0..<80).map { index in
            NativePlaybackSidebarLayout.Entry(
                indexPath: IndexPath(item: index, section: 0),
                itemID: .commentThread(
                    subject: subject,
                    rootID: CommentID(rawValue: Int64(index + 1))
                )
            )
        }
        var measurements = 0
        layout.heightProvider = { _, width in
            measurements += 1
            return 80 + width.truncatingRemainder(dividingBy: 7)
        }
        layout.update(entries: entries)
        layout.prepare()
        #expect(measurements == 80)

        collectionView.frame.size.width = 520
        layout.invalidateLayout()
        layout.prepare()
        #expect(layout.pendingRefinementIndexes.count == 80)
        #expect(measurements == 80)

        #expect(
            layout.refineNextBatch(
                maximumCount: 32,
                prioritizing: entries[40].itemID
            )
        )
        #expect(measurements == 112)
        #expect(layout.pendingRefinementIndexes.count == 48)
    }

    @Test
    @MainActor
    func commentAppendMeasuresOnlyNewRowsAndTheMovedFooter() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 0, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 1))
        )
        let oldFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        let second = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 2))
        )
        let movedFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 2, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        var measurements = 0
        layout.heightProvider = { _, _ in
            measurements += 1
            return 80
        }

        layout.update(entries: [first, oldFooter])
        layout.prepare()
        #expect(measurements == 2)
        layout.update(
            entries: [first, second, movedFooter],
            invalidating: [second.itemID, movedFooter.itemID]
        )
        layout.prepare()

        #expect(measurements == 4)
        #expect(
            layout.layoutAttributesForItem(at: movedFooter.indexPath)?.frame.minY
                == 208
        )
    }

    @Test
    @MainActor
    func commentAppendPreservesPendingPrefixRefinementAfterResize() {
        let layout = NativePlaybackSidebarLayout()
        let collectionView = NSCollectionView(
            frame: NSRect(x: 0, y: 0, width: 440, height: 600)
        )
        collectionView.collectionViewLayout = layout
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let first = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 0, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 1))
        )
        let oldFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        let second = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 1, section: 0),
            itemID: .commentThread(subject: subject, rootID: CommentID(rawValue: 2))
        )
        let movedFooter = NativePlaybackSidebarLayout.Entry(
            indexPath: IndexPath(item: 2, section: 0),
            itemID: .commentsFooter(subject: subject)
        )
        var measurements = 0
        layout.heightProvider = { _, _ in
            measurements += 1
            return 80
        }
        layout.update(entries: [first, oldFooter])
        layout.prepare()

        collectionView.frame.size.width = 520
        layout.invalidateLayout()
        layout.prepare()
        #expect(layout.pendingRefinementIndexes == IndexSet(integersIn: 0..<2))
        #expect(measurements == 2)

        layout.update(
            entries: [first, second, movedFooter],
            invalidating: [second.itemID, movedFooter.itemID]
        )
        layout.prepare()

        #expect(layout.pendingRefinementIndexes == IndexSet(integer: 0))
        #expect(measurements == 4)
        #expect(layout.layoutAttributesForItem(at: movedFooter.indexPath) != nil)
    }

    @Test
    func shortLoadingContentIsNeverTreatedAsBottomPinned() {
        let viewport = NSRect(x: 0, y: 0, width: 440, height: 600)

        #expect(
            !NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 420,
                viewport: viewport
            )
        )
        #expect(
            NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 1_200,
                viewport: NSRect(x: 0, y: 600, width: 440, height: 600)
            )
        )
        #expect(
            !NativePlaybackSidebarAnchorPolicy.isBottomPinned(
                contentHeight: 1_200,
                viewport: viewport
            )
        )
    }

    @Test
    func firstPresentedVideoAndReplacementBothResetToTop() {
        #expect(
            NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: nil,
                nextBVID: "BVFirst"
            )
        )
        #expect(
            NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: "BVSecond"
            )
        )
        #expect(
            !NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: "BVFirst"
            )
        )
        #expect(
            !NativePlaybackSidebarIdentityPolicy.resetsToTop(
                previousBVID: "BVFirst",
                nextBVID: nil
            )
        )
    }

    @Test
    @MainActor
    func initialCommentsSnapshotRestoresTopBeforeConsideringFooterPagination() async throws {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        controller.rootView.layoutSubtreeIfNeeded()
        let subject = CommentSubjectIdentity.video(aid: 700_001)
        let loading = NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loading,
            totalCount: 0,
            threads: []
        )
        let loaded = commentsPresentation(
            subject: subject,
            threads: (1...40).map {
                commentThread(id: Int64($0), message: "第 \($0) 条评论正文")
            }
        )
        var nextPageRequests = 0
        let testActions = NativePlaybackSidebarActions(
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {},
            selectCommentSort: { _ in },
            retryComments: {},
            loadNextComments: { nextPageRequests += 1 },
            expandReplies: { _ in },
            collapseReplies: { _ in },
            previousReplyPage: { _ in },
            nextReplyPage: { _ in },
            retryReplies: { _ in },
            openCommentLink: { _ in },
            openCommentPictures: { _ in }
        )

        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loading),
            actions: testActions
        )
        controller.update(
            presentation: presentation(bvid: "BVFirst", comments: loaded),
            actions: testActions
        )
        #expect(
            await waitUntil(timeout: .seconds(5)) {
                guard
                    let collectionView = controller.rootView.scrollView.documentView
                        as? NSCollectionView
                else { return false }
                controller.rootView.layoutSubtreeIfNeeded()
                return collectionView.numberOfSections == 4
                    && collectionView.numberOfItems(inSection: 3) == 42
                    && (collectionView.collectionViewLayout?.collectionViewContentSize.height
                        ?? 0) > 600
            }
        )

        #expect(controller.rootView.scrollView.documentVisibleRect.minY <= 1)
        #expect(nextPageRequests == 0)
        let collectionView = try #require(
            controller.rootView.scrollView.documentView as? NSCollectionView
        )
        #expect(collectionView.numberOfSections == 4)
        #expect(collectionView.numberOfItems(inSection: 3) == 42)
        #expect(
            collectionView.collectionViewLayout?.collectionViewContentSize.height
                ?? 0 > 600
        )
        controller.tearDown()
    }

    @MainActor
    private var actions: NativePlaybackSidebarActions {
        NativePlaybackSidebarActions(
            selectEpisode: { _ in },
            selectPage: { _, _ in },
            retryPages: {},
            selectCommentSort: { _ in },
            retryComments: {},
            loadNextComments: {},
            expandReplies: { _ in },
            collapseReplies: { _ in },
            previousReplyPage: { _ in },
            nextReplyPage: { _ in },
            retryReplies: { _ in },
            openCommentLink: { _ in },
            openCommentPictures: { _ in }
        )
    }

    /// 侧栏文档里真正能拿到焦点的两类 responder：可选择的文本视图本身，以及可选择文本框
    /// 编辑会话里由窗口共享的 field editor。
    enum SidebarFocus: CaseIterable {
        case selectableTextView
        case textFieldEditor
    }

    final class ResignRecordingTextView: NSTextView {
        private(set) var didResign = false

        override func resignFirstResponder() -> Bool {
            didResign = true
            return super.resignFirstResponder()
        }
    }

    /// 用可记录 resign 的 field editor 代替窗口共享的 field editor。
    final class RecordingFieldEditorWindow: NSWindow {
        private lazy var recordingFieldEditor: ResignRecordingTextView = {
            let fieldEditor = ResignRecordingTextView()
            fieldEditor.isFieldEditor = true
            return fieldEditor
        }()

        override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
            recordingFieldEditor
        }
    }

    /// 把侧栏装进窗口，并在侧栏外放一个可接焦点的视图，代表窗口里的其他控件。
    @MainActor
    private func hostedSidebar() -> (
        controller: NativePlaybackSidebarController,
        window: NSWindow,
        outsideKeyView: NSView
    ) {
        let controller = NativePlaybackSidebarController()
        controller.rootView.frame = NSRect(x: 0, y: 0, width: 440, height: 600)
        let window = RecordingFieldEditorWindow(
            contentRect: controller.rootView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.rootView
        controller.update(
            presentation: presentation(bvid: "BVCurrent"),
            actions: actions
        )
        let outsideKeyView = selectableTextView()
        controller.rootView.addSubview(outsideKeyView)
        return (controller, window, outsideKeyView)
    }

    /// 让焦点真正落进侧栏文档并返回持有焦点的 responder。
    ///
    /// 直接把裸 field editor 设为 first responder 不会生效（窗口自己会接回焦点），所以
    /// field editor 必须来自文本框真正开始的编辑会话。AppKit 隐藏焦点视图时沿持有焦点的
    /// responder 找下一个 key view，因此把它（而不是文本框）的下一个 key view 指向侧栏外。
    @MainActor
    private func focusInsideSidebar(
        _ focus: SidebarFocus,
        of controller: NativePlaybackSidebarController,
        in window: NSWindow,
        nextKeyView outsideKeyView: NSView
    ) -> ResignRecordingTextView? {
        let documentView = controller.rootView.scrollView.documentView
        let focused: ResignRecordingTextView?
        switch focus {
        case .selectableTextView:
            let textView = selectableTextView()
            documentView?.addSubview(textView)
            window.makeFirstResponder(textView)
            focused = textView
        case .textFieldEditor:
            let selectableField = NSTextField(labelWithString: "可选择的标题")
            selectableField.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
            selectableField.isSelectable = true
            documentView?.addSubview(selectableField)
            selectableField.selectText(nil)
            focused = selectableField.currentEditor() as? ResignRecordingTextView
        }
        focused?.nextKeyView = outsideKeyView
        return focused
    }

    @MainActor
    private func selectableTextView() -> ResignRecordingTextView {
        let textView = ResignRecordingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        textView.isEditable = false
        textView.isSelectable = true
        return textView
    }

    @MainActor
    private func presentation(bvid: String) -> NativePlaybackSidebarPresentation {
        presentation(
            bvid: bvid,
            comments: NativePlaybackCommentsPresentation(model: nil)
        )
    }

    @MainActor
    private func presentation(
        bvid: String,
        comments: NativePlaybackCommentsPresentation
    ) -> NativePlaybackSidebarPresentation {
        let context = context(bvid: bvid)
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: bvid,
                uploader: VideoUploaderHeaderContent(
                    owner: context.detail.owner,
                    profileState: .loaded(
                        UploaderProfile(signature: context.detail.owner.signature)
                    )
                ),
                summary: context.detail.summary,
                summaryLinks: context.detail.summaryLinks,
                selection: selectionProjection(context: context),
                comments: comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        )
    }

    @MainActor
    private func commentsPresentation(
        subject: CommentSubjectIdentity,
        threads: [CommentThread],
        isLoadingNextPage: Bool = false
    ) -> NativePlaybackCommentsPresentation {
        NativePlaybackCommentsPresentation(
            subject: subject,
            sort: .hot,
            rootState: .loaded,
            totalCount: threads.count,
            threads: threads.map {
                NativePlaybackCommentThreadPresentation(
                    subject: subject,
                    thread: $0,
                    replyState: nil
                )
            },
            isLoadingNextPage: isLoadingNextPage
        )
    }

    @MainActor
    private func commentItemIDs(
        _ comments: NativePlaybackCommentsPresentation
    ) -> [NativePlaybackSidebarItemID] {
        let base = presentation(bvid: "BVCurrent")
        guard let content = base.content else { return [] }
        return NativePlaybackSidebarPresentation(
            content: NativePlaybackSidebarContent(
                bvid: content.bvid,
                uploader: content.uploader,
                summary: content.summary,
                summaryLinks: content.summaryLinks,
                selection: content.selection,
                comments: comments,
                timestampLimitSeconds: nil
            ),
            overlay: .none
        ).sections.first { $0.id == .comments }?.items ?? []
    }

    private func heightKey(rootID: Int64) -> NativePlaybackSidebarHeightCacheKey {
        NativePlaybackSidebarHeightCacheKey(
            itemID: .commentThread(
                subject: .video(aid: 700_001),
                rootID: CommentID(rawValue: rootID)
            ),
            widthBucket: 816,
            revision: Int(rootID)
        )
    }

    private func commentThread(
        id: Int64,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        preview: [BiliModels.Comment] = [],
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> CommentThread {
        CommentThread(
            root: comment(
                id: id,
                message: message,
                links: links,
                pictures: pictures,
                pictureCount: pictureCount,
                replyCount: replyCount,
                author: author,
                provenance: provenance
            ),
            replyPreview: preview
        )
    }

    private func comment(
        id: Int64,
        rootID: Int64? = nil,
        message: String,
        links: [CommentLink] = [],
        pictures: [CommentImage] = [],
        pictureCount: Int? = nil,
        replyCount: Int = 0,
        author: CommentAuthor? = nil,
        provenance: [CommentProvenance] = []
    ) -> BiliModels.Comment {
        BiliModels.Comment(
            id: CommentID(rawValue: id),
            rootID: rootID.map { CommentID(rawValue: $0) },
            payload: .available(
                CommentDetails(
                    author: author
                        ?? CommentAuthor(
                            id: CommentAuthorID(rawValue: "author-\(id)"),
                            name: "评论者\(id)",
                            level: 6,
                            isVIP: true
                        ),
                    content: CommentContent(
                        message: message,
                        links: links,
                        pictures: pictures,
                        pictureCount: pictureCount
                    ),
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    location: "东京",
                    likeCount: 42,
                    replyCount: replyCount,
                    provenance: provenance
                )
            )
        )
    }

    @MainActor
    private func selectionProjection(
        context: VideoContext? = nil
    ) -> PlaybackSelectionProjection {
        let context = context ?? self.context(bvid: "BVCurrent")
        return PlaybackSelectionProjection(
            context: context,
            selectedEpisodeID: nil,
            requestedBVID: context.detail.bvid,
            requestedCID: context.pages.first?.cid,
            presentedIdentity: nil,
            pageStates: [:],
            pagesByEpisode: [:]
        )
    }

    private func context(
        bvid: String,
        collection: VideoCollection? = nil
    ) -> VideoContext {
        let pages = [
            VideoPage(cid: 1_001, index: 1, title: "第一部分", durationSeconds: 61),
            VideoPage(cid: 1_002, index: 2, title: "第二部分", durationSeconds: 122)
        ]
        return VideoContext(
            detail: VideoDetail(
                bvid: bvid,
                title: "当前视频",
                summary: "一段可选择、可精确换行的简介正文。",
                coverURL: nil,
                owner: VideoOwner(id: 1, name: "UP 主", signature: "签名"),
                statistics: VideoStatistics(
                    viewCount: 1,
                    danmakuCount: 1,
                    likeCount: 1
                ),
                durationSeconds: 122,
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pages: pages,
                collection: collection
            ),
            pages: pages,
            selectedPage: pages[0],
            playback: VideoPlayback(
                manifest: PlaybackManifest(
                    videoRepresentations: [],
                    originalAudioRepresentations: []
                ),
                mediaHeaders: [:]
            )
        )
    }

    private func collectionSection(
        id: Int64,
        title: String,
        episodes: [VideoCollectionEpisode]
    ) -> VideoCollectionSection {
        VideoCollectionSection(
            id: VideoCollectionSectionIdentity(seasonID: 1, sectionID: id),
            ordinal: Int(id - 10),
            title: title,
            episodes: episodes
        )
    }

    private func collectionEpisode(
        sectionID: Int64,
        episodeID: Int64,
        bvid: String,
        title: String
    ) -> VideoCollectionEpisode {
        VideoCollectionEpisode(
            id: VideoCollectionEpisodeIdentity(
                seasonID: 1,
                sectionID: sectionID,
                episodeID: episodeID
            ),
            ordinal: Int(episodeID - 100),
            aid: nil,
            bvid: bvid,
            title: title,
            coverURL: nil,
            durationSeconds: 122,
            defaultCID: 1_001,
            knownPages: [
                VideoPage(
                    cid: 1_001,
                    index: 1,
                    title: "第一部分",
                    durationSeconds: 61
                )
            ]
        )
    }

    @MainActor
    private func makeCommentTextRenderer(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentTextRenderer {
        NativePlaybackCommentTextRenderer(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func makeCommentAvatarLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentAvatarLoader {
        NativePlaybackCommentAvatarLoader(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func makeCommentPictureLoader(
        resolveURL: @escaping CommentAssetURLResolver = { _, _ in nil }
    ) -> NativePlaybackCommentPictureLoader {
        NativePlaybackCommentPictureLoader(
            imagePipeline: NativeVideoImagePipeline(),
            resolveURL: resolveURL
        )
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
