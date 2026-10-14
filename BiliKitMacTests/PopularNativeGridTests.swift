import AppKit
import BiliBrowseFeature
import BiliModels
import BiliUI
import CoreGraphics
import Foundation
import Testing

@testable import BiliKit

@Suite(.timeLimit(.minutes(1)))
struct PopularNativeGridTests {
    @Test
    func updatePlanDescribesAppendReloadAndRemovalWithoutFullReloadContract() {
        let plan = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b", "BV-remove"],
            previousContents: [
                "BV-a": "old",
                "BV-b": "same",
                "BV-remove": "gone"
            ],
            updatedIDs: ["BV-a", "BV-b", "BV-new"],
            updatedContents: [
                "BV-a": "updated",
                "BV-b": "same",
                "BV-new": "inserted"
            ]
        )

        #expect(plan.identityChanged)
        #expect(plan.insertedIDs == ["BV-new"])
        #expect(plan.removedIDs == ["BV-remove"])
        #expect(plan.changedExistingIDs == ["BV-a"])
        #expect(!plan.isStrictTailAppend)
    }

    @Test
    func unchangedIdentityReloadsOnlyChangedExistingCard() {
        let plan = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "old", "BV-b": "same"],
            updatedIDs: ["BV-a", "BV-b"],
            updatedContents: ["BV-a": "new", "BV-b": "same"]
        )

        #expect(!plan.identityChanged)
        #expect(plan.insertedIDs.isEmpty)
        #expect(plan.removedIDs.isEmpty)
        #expect(plan.changedExistingIDs == ["BV-a"])
        #expect(!plan.isStrictTailAppend)
    }

    @Test
    func strictTailAppendPreservesExistingGeometryWithoutReorder() {
        let append = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "same"],
            updatedIDs: ["BV-a", "BV-b", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "same", "BV-c": "inserted"]
        )
        let appendWithReload = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "old"],
            updatedIDs: ["BV-a", "BV-b", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "new", "BV-c": "inserted"]
        )
        let reorder = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b"],
            previousContents: ["BV-a": "same", "BV-b": "same"],
            updatedIDs: ["BV-b", "BV-a", "BV-c"],
            updatedContents: ["BV-a": "same", "BV-b": "same", "BV-c": "inserted"]
        )

        #expect(append.isStrictTailAppend)
        #expect(!append.restoresViewportAnchor)
        #expect(append.insertedIDs == ["BV-c"])
        #expect(append.changedExistingIDs.isEmpty)
        #expect(appendWithReload.isStrictTailAppend)
        #expect(!appendWithReload.restoresViewportAnchor)
        #expect(appendWithReload.changedExistingIDs == ["BV-b"])
        #expect(!reorder.isStrictTailAppend)
        #expect(reorder.restoresViewportAnchor)
    }

    @Test
    func replacementKeepsAnchorOnlyWhileAnchorCardRemains() {
        let refresh = NativeVideoGridUpdatePlan(
            previousIDs: ["BV-a", "BV-b", "BV-c"],
            previousContents: ["BV-a": "same", "BV-b": "same", "BV-c": "same"],
            updatedIDs: ["BV-new", "BV-a"],
            updatedContents: ["BV-new": "inserted", "BV-a": "same"]
        )

        let keptAnchor = NativeVideoGridViewportAnchor(id: "BV-a", offsetFromViewportTop: 0)
        let replacedAnchor = NativeVideoGridViewportAnchor(id: "BV-c", offsetFromViewportTop: 0)

        #expect(refresh.retains(keptAnchor))
        #expect(!refresh.retains(replacedAnchor))
    }

    @Test
    func scrollResetGateConsumesEachRequestIdentityOnlyOnce() {
        var gate = NativeVideoGridScrollResetGate(initialRequestID: 7)

        let sameInitialRequest = gate.consume(7)
        let nextRequest = gate.consume(8)
        let repeatedNextRequest = gate.consume(8)
        let laterRequest = gate.consume(9)

        #expect(!sameInitialRequest)
        #expect(nextRequest)
        #expect(!repeatedNextRequest)
        #expect(laterRequest)
    }

    @Test
    func scrollResetStateKeepsUnacknowledgedRequestAcrossGridRecreation() {
        var state = NativeVideoGridScrollResetState()

        state.request()
        #expect(state.requestID == 1)
        #expect(state.acknowledgedRequestID == 0)

        var recreatedGate = NativeVideoGridScrollResetGate(
            initialRequestID: state.acknowledgedRequestID
        )
        let recreatedGridConsumesPendingRequest = recreatedGate.consume(
            state.requestID
        )
        #expect(recreatedGridConsumesPendingRequest)
        state.acknowledgedRequestID = state.requestID

        var laterGate = NativeVideoGridScrollResetGate(
            initialRequestID: state.acknowledgedRequestID
        )
        let laterGridReplaysAcknowledgedRequest = laterGate.consume(
            state.requestID
        )
        #expect(!laterGridReplaysAcknowledgedRequest)
    }

    @Test
    func anchorRetentionPreservesItemOffsetAndClampsBounds() {
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 1_200,
                offsetFromViewportTop: 40,
                maximumOffsetY: 2_000
            ) == 1_160
        )
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 2_400,
                offsetFromViewportTop: 20,
                maximumOffsetY: 2_000
            ) == 2_000
        )
        #expect(
            NativeVideoGridAnchorRetention.targetOffsetY(
                itemOriginY: 10,
                offsetFromViewportTop: 40,
                minimumOffsetY: -52,
                maximumOffsetY: 2_000
            ) == -30
        )
    }

    /// 纵向 toolbar inset（网格）与横向侧栏 inset（shelf）共用同一逻辑坐标换算。
    @Test(arguments: [
        (physical: CGFloat(-52), inset: CGFloat(52), logical: CGFloat(0)),
        (physical: 0, inset: 52, logical: 52),
        (physical: -320, inset: 320, logical: 0),
        (physical: 160, inset: 320, logical: 480)
    ])
    func logicalScrollOffsetIncludesLeadingInset(
        _ sample: (physical: CGFloat, inset: CGFloat, logical: CGFloat)
    ) {
        #expect(
            NativeVideoScrollCoordinateSpace.logicalOffset(
                physicalOffset: sample.physical,
                leadingInset: sample.inset
            ) == sample.logical
        )
        #expect(
            NativeVideoScrollCoordinateSpace.physicalOffset(
                logicalOffset: sample.logical,
                leadingInset: sample.inset
            ) == sample.physical
        )
    }

    @Test
    func maximumLogicalScrollOffsetIncludesBothInsets() {
        #expect(
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: 2_686,
                viewportLength: 1_050,
                leadingInset: 52,
                trailingInset: 0
            ) == 1_688
        )
        #expect(
            NativeVideoScrollCoordinateSpace.maximumLogicalOffset(
                documentLength: 1_472,
                viewportLength: 900,
                leadingInset: 320,
                trailingInset: 0
            ) == 892
        )
    }

    @Test
    func scrollRetentionKeepsLastObservedOffsetForSurfaceTeardown() {
        var retention = NativeVideoScrollOffsetRetention(initialOffsetY: -10)
        #expect(retention.offsetY == 0)
        #expect(retention.takePendingPersistence() == nil)

        for offset in stride(from: CGFloat(10), through: 1_240, by: 10) {
            retention.record(offset)
        }

        #expect(retention.offsetY == 1_240)
        #expect(retention.takePendingPersistence() == 1_240)
        #expect(retention.takePendingPersistence() == nil)

        retention.record(1_240.4)
        #expect(retention.takePendingPersistence() == nil)
        retention.record(1_300)
        retention.markPersisted(1_300)
        #expect(retention.takePendingPersistence() == nil)
    }

    @Test
    func scrollBindingBridgeDistinguishesEchoFromExternalTopRequest() {
        var bridge = NativeVideoScrollBindingBridge(initialOffsetY: 1_200)

        #expect(bridge.takeExternalRequest(1_200) == nil)
        bridge.markSynchronized(1_500)
        #expect(bridge.takeExternalRequest(1_500) == nil)
        #expect(bridge.takeExternalRequest(0) == 0)
        #expect(bridge.takeExternalRequest(0) == nil)
    }

    /// 网格刚把位置同步出去时，同一轮更新里交回的旧值不算新请求；binding 赶上新值后旧值才重新算请求。
    @Test
    func scrollBindingBridgeIgnoresTheValueItJustReplaced() {
        var bridge = NativeVideoScrollBindingBridge(initialOffsetY: 3_066)

        bridge.markSynchronized(0)
        #expect(bridge.takeExternalRequest(3_066) == nil)
        #expect(bridge.takeExternalRequest(0) == nil)
        #expect(bridge.takeExternalRequest(3_066) == 3_066)
    }

    /// 程序回到顶部后、用户再次滚动前保持置顶；滚动代次前进后置顶失效。
    @Test
    func topPinHoldsOnlyUntilTheUserScrollsAgain() {
        var pin = NativeVideoGridTopPin()
        #expect(!pin.keepsTop(atScrollGeneration: 0))

        pin.pin(atScrollGeneration: 3)

        #expect(pin.keepsTop(atScrollGeneration: 3))
        #expect(!pin.keepsTop(atScrollGeneration: 4))
    }

    /// 视野底边离内容底部不足 `nearEndViewportMultiple` 屏时请求下一页，与可见卡片无关。
    @Test
    func nearEndTriggersWithinTheNearEndMultipleOfTheContentBottom() {
        let width: CGFloat = 1_080
        let viewportHeight: CGFloat = 800
        let contentHeight = NativeVideoGridGeometry.contentHeight(for: width, itemCount: 100)
        let threshold =
            contentHeight - viewportHeight * NativeVideoGridGeometry.nearEndViewportMultiple

        #expect(
            !NativeVideoGridGeometry.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold,
                viewportHeight: viewportHeight
            )
        )
        #expect(
            NativeVideoGridGeometry.isNearEnd(
                itemCount: 100,
                width: width,
                visibleMaximumY: threshold + 1,
                viewportHeight: viewportHeight
            )
        )
        #expect(
            !NativeVideoGridGeometry.isNearEnd(
                itemCount: 0,
                width: width,
                visibleMaximumY: 10_000,
                viewportHeight: viewportHeight
            )
        )
    }

    /// 预备区域是视野上下各 `preparedViewportMultiple` 屏，夹在内容范围内；某一侧余量少于
    /// `preparedRefreshViewportMultiple` 屏时才刷新，已到内容边缘的一侧不算不足。
    @Test
    func preparedContentKeepsAMarginAroundTheVisibleRect() {
        let bounds = NSRect(x: 0, y: 0, width: 1_000, height: 20_000)
        let visible = NSRect(x: 0, y: 8_000, width: 1_000, height: 800)
        let margin = visible.height * NativeVideoGridGeometry.preparedViewportMultiple
        let slack = visible.height * NativeVideoGridGeometry.preparedRefreshViewportMultiple
        let target = visible.insetBy(dx: 0, dy: -margin)

        #expect(
            NativeVideoGridGeometry.preparedContentRect(visible: visible, bounds: bounds) == target
        )
        let atTop = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        #expect(
            NativeVideoGridGeometry.preparedContentRect(visible: atTop, bounds: bounds)
                == NSRect(x: 0, y: 0, width: 1_000, height: atTop.height + margin)
        )
        #expect(
            !NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: target,
                visible: visible,
                bounds: bounds
            )
        )
        var shortBelow = target
        shortBelow.size.height = visible.maxY + slack - 1 - target.minY
        #expect(
            NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: shortBelow,
                visible: visible,
                bounds: bounds
            )
        )
        var shortAbove = target
        shortAbove.origin.y = visible.minY - slack + 1
        shortAbove.size.height = target.maxY - shortAbove.minY
        #expect(
            NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: shortAbove,
                visible: visible,
                bounds: bounds
            )
        )
        #expect(
            NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: .zero,
                visible: visible,
                bounds: bounds
            )
        )
        // 视野已到内容底部：下方没有可准备的内容，不算余量不足。
        let bottom = NSRect(x: 0, y: bounds.maxY - 800, width: 1_000, height: 800)
        #expect(
            !NativeVideoGridGeometry.needsPreparedContentRefresh(
                prepared: NativeVideoGridGeometry.preparedContentRect(
                    visible: bottom,
                    bounds: bounds
                ),
                visible: bottom,
                bounds: bounds
            )
        )
    }

    @Test
    func operationEpochRejectsSupersededSnapshotCompletion() {
        var epoch = NativeVideoGridOperationEpoch()
        let first = epoch.advance()
        let second = epoch.advance()

        #expect(!epoch.accepts(first))
        #expect(epoch.accepts(second))
    }

    @Test
    @MainActor
    func hoverTrackerDropsCardThatEndsDisplayingBeforeReuse() {
        let tracker = NativeVideoHoverTracker()
        let hovered = NativeVideoCollectionItem()
        let other = NativeVideoCollectionItem()
        tracker.setHoveredItem(hovered)

        tracker.itemDidEndDisplaying(other)
        #expect(tracker.hoveredItem === hovered)

        tracker.itemDidEndDisplaying(hovered)
        #expect(tracker.hoveredItem == nil)
    }

    @Test
    func imageApplicationGateRejectsCancellationAndLateCoverOrAvatarReuse() {
        let current = NativeVideoReuseIdentity(itemID: "BV-current", generation: 8)
        #expect(
            NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: false
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: current,
                isCancelled: true
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: NativeVideoReuseIdentity(
                    itemID: "BV-current",
                    generation: 7
                ),
                isCancelled: false
            )
        )
        #expect(
            !NativeVideoImageApplicationGate.accepts(
                currentIdentity: current,
                resultIdentity: NativeVideoReuseIdentity(
                    itemID: "BV-old",
                    generation: 8
                ),
                isCancelled: false
            )
        )
    }

    @Test
    func imagePipelineBoundsResponseAndDecodedCache() throws {
        let megabyte = 1_024 * 1_024
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(-1, maximumBytes: 8))
        #expect(NativeVideoImagePipeline.acceptsExpectedLength(8, maximumBytes: 8))
        #expect(!NativeVideoImagePipeline.acceptsExpectedLength(9, maximumBytes: 8))
        // 只有评论图片预览请求原图（B 站上传上限 20 MB），其余用途保持 8 MiB。
        #expect(NativeVideoImageVariant.commentPicturePreview.maximumResponseBytes == 20 * megabyte)
        for variant in [
            NativeVideoImageVariant.cover, .avatar, .commentEmote, .commentPicture,
            .trendingSearchIcon
        ] {
            #expect(variant.maximumResponseBytes == 8 * megabyte)
        }

        var countBoundCache = NativeVideoImageCache(
            countLimit: 2,
            costLimit: 1_024
        )
        let image = try #require(makeImage(width: 4, height: 4))
        countBoundCache.insert(image, animation: nil, for: imageKey("1"))
        countBoundCache.insert(image, animation: nil, for: imageKey("2"))
        countBoundCache.insert(image, animation: nil, for: imageKey("3"))
        #expect(countBoundCache.count == 2)
        #expect(countBoundCache.totalCost <= 1_024)

        var costBoundCache = NativeVideoImageCache(
            countLimit: 10,
            costLimit: 100
        )
        costBoundCache.insert(image, animation: nil, for: imageKey("a"))
        costBoundCache.insert(image, animation: nil, for: imageKey("b"))
        #expect(costBoundCache.totalCost <= 100)
        #expect(costBoundCache.count <= 1)
    }

    @Test
    func imageVariantsUseDistinctCacheIdentities() throws {
        let url = try #require(URL(string: "https://i.example/shared.webp"))
        let coverKey = NativeVideoImageKey(url: url, variant: .cover)
        let avatarKey = NativeVideoImageKey(url: url, variant: .avatar)
        let commentPictureKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicture
        )
        let commentPreviewKey = NativeVideoImageKey(
            url: url,
            variant: .commentPicturePreview
        )
        #expect(commentPictureKey != commentPreviewKey)
        let cover = try #require(makeImage(width: 8, height: 4))
        let avatar = try #require(makeImage(width: 4, height: 4))
        var cache = NativeVideoImageCache(countLimit: 2, costLimit: 1_024)

        cache.insert(cover, animation: nil, for: coverKey)
        cache.insert(avatar, animation: nil, for: avatarKey)

        #expect(cache.count == 2)
        #expect(cache.image(for: coverKey)?.width == 8)
        #expect(cache.image(for: avatarKey)?.width == 4)
    }

    @Test
    func imageVariantsEnforceDecodedPixelBounds() throws {
        let source = try #require(makeImage(width: 1_000, height: 1_000))
        let data = try #require(
            NSBitmapImageRep(cgImage: source).representation(
                using: .png,
                properties: [:]
            )
        )
        let cover = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .cover)
        )
        let avatar = try #require(
            NativeVideoImagePipeline.decodeImage(data, variant: .avatar)
        )

        #expect(max(cover.width, cover.height) == 640)
        #expect(max(avatar.width, avatar.height) == 96)
    }

    @Test
    func imagePipelineShutdownRejectsFutureRequestsBeforeTouchingSession() async {
        let pipeline = NativeVideoImagePipeline()
        pipeline.shutdown()

        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-shutdown.webp")!,
            variant: .cover
        )

        #expect(result == nil)
    }

    @Test
    func imageSessionGateSerializesRegistrationAndInvalidation() {
        let gate = NativeVideoImageSessionGate()
        let session = URLSession(configuration: .ephemeral)
        var registrationCount = 0

        #expect(gate.register { registrationCount += 1 })
        gate.invalidate(session)
        #expect(!gate.register { registrationCount += 1 })
        #expect(registrationCount == 1)
    }

    @Test
    func releasingImageOwnerSynchronouslyInvalidatesRetainedPipeline() async {
        var owner: NativeVideoImagePipelineOwner? = NativeVideoImagePipelineOwner()
        weak let weakOwner = owner
        let pipeline = owner!.pipeline

        owner = nil
        let result = await pipeline.image(
            for: URL(string: "https://i.example/after-owner-release.webp")!,
            variant: .cover
        )

        #expect(weakOwner == nil)
        #expect(result == nil)
    }

    @Test
    func imageResponseAccumulatorRejectsChunkBeforeExceedingBound() {
        var accumulator = NativeVideoImageResponseAccumulator(maximumBytes: 8)

        let acceptedFirst = accumulator.append(Data(repeating: 1, count: 6))
        let rejectedOverflow = accumulator.append(Data(repeating: 2, count: 3))
        #expect(accumulator.data.count == 6)
        let acceptedBoundary = accumulator.append(Data(repeating: 3, count: 2))

        #expect(acceptedFirst)
        #expect(!rejectedOverflow)
        #expect(acceptedBoundary)
        #expect(accumulator.data.count == 8)
    }

    @Test @MainActor
    func recommendationMappingUsesBrandCapsuleOnlyWhenReasonExists() throws {
        let video = RecommendedVideo(
            bvid: "BV-rcmd-stable",
            title: "首页推荐卡片",
            coverURL: nil,
            owner: VideoOwner(id: 1, name: "作者"),
            statistics: VideoStatistics(viewCount: 10, danmakuCount: 2, likeCount: 3),
            durationSeconds: 125,
            publishedAt: Date(timeIntervalSince1970: 0),
            recommendationReason: "正在流行"
        )

        let content = try #require(
            RecommendedNativeGridView.makePresentations([video, video]).first
        )
        #expect(RecommendedNativeGridView.makePresentations([video, video]).count == 1)
        #expect(content.footerTrailingText == "正在流行")
        #expect(content.footerTrailingStyle == .brandOutlinedCapsule)
        #expect(
            content.accessibilityLabel
                == RecommendedVideoCardPresentation(video: video).accessibilityLabel
        )

        let withoutReason = RecommendedVideo(
            bvid: "BV-rcmd-plain",
            title: video.title,
            coverURL: nil,
            owner: video.owner,
            statistics: video.statistics,
            durationSeconds: video.durationSeconds,
            publishedAt: video.publishedAt,
            recommendationReason: nil
        )
        let plain = try #require(
            RecommendedNativeGridView.makePresentations([withoutReason]).first
        )
        #expect(plain.footerTrailingText == nil)
        #expect(plain.footerTrailingStyle == .plain)
    }

    @Test
    func historyFooterReservesMeasuredWidthWithoutTruncatingTime() {
        let measured = NativeVideoCardTextLayout.singleLineWidth(
            "12月31日 19:59",
            font: .preferredFont(forTextStyle: .body)
        )
        let widths = NativeVideoCardLayout.footerWidths(
            contentWidth: 300,
            leadingInset: 0,
            trailingIntrinsicWidth: measured,
            showsTrailing: true
        )

        #expect(widths.trailing == measured)
        #expect(widths.leading + widths.trailing + NativeVideoCardLayout.footerSpacing == 300)
    }

    @Test
    func recommendationCapsulePreservesUploaderFooterWidth() {
        let widths = NativeVideoCardLayout.recommendationFooterWidths(
            contentWidth: 224,
            leadingInset: 44,
            capsuleIntrinsicWidth: 500
        )

        #expect(
            widths.leading
                >= NativeVideoCardLayout.recommendationFooterMinimumLeadingWidth
        )
        #expect(
            widths.leading + widths.trailing
                + NativeVideoCardTextLayout.recommendationCapsuleSpacing
                == 180
        )
    }

    @Test
    func footerTrailingWidthCacheMeasuresOnlyWhenTextChanges() {
        var cache = NativeVideoSingleLineWidthCache()
        var measurements = 0

        let first = cache.width(for: "今天 19:59") {
            measurements += 1
            return 80
        }
        let repeated = cache.width(for: "今天 19:59") {
            measurements += 1
            return 999
        }
        let changed = cache.width(for: "12月31日 19:59") {
            measurements += 1
            return 100
        }
        cache.reset()
        let afterReset = cache.width(for: "12月31日 19:59") {
            measurements += 1
            return 101
        }

        #expect(first == 80)
        #expect(repeated == 80)
        #expect(changed == 100)
        #expect(afterReset == 101)
        #expect(measurements == 3)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context?.makeImage()
    }

    private func imageKey(
        _ path: String,
        variant: NativeVideoImageVariant = .cover
    ) -> NativeVideoImageKey {
        NativeVideoImageKey(
            url: URL(fileURLWithPath: "/native-video-cache/\(path)"),
            variant: variant
        )
    }
}
