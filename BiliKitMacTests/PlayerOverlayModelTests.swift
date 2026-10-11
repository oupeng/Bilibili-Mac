import AVFoundation
import AppKit
import BiliApplication
import BiliBrowseFeature
import SwiftUI
import Testing

@testable import BiliKit

@MainActor
struct PlayerOverlayModelTests {
    @Test
    func heldMomentaryRateStaysUntilEndedWhileOtherFeedbackExpires() throws {
        let model = PlayerOverlayModel()

        model.showFeedback(.volume(40))
        let transient = try #require(model.feedback)
        #expect(transient.dismissesAutomatically)
        model.endMomentaryRate()
        #expect(model.feedback == transient)

        model.showMomentaryRate(.fast)
        let held = try #require(model.feedback)
        #expect(held.content == .momentaryRate(.fast))
        #expect(!held.dismissesAutomatically)
        model.expireFeedback(id: transient.id)
        #expect(model.feedback == held)

        model.endMomentaryRate()
        #expect(model.feedback == nil)
    }

    @Test
    func feedbackExpiryOnlyRemovesTheScheduledBadge() throws {
        let model = PlayerOverlayModel()
        model.showFeedback(.playback(true))
        let first = try #require(model.feedback)
        model.showFeedback(.playback(false))
        let replacement = try #require(model.feedback)

        model.expireFeedback(id: first.id)
        #expect(model.feedback == replacement)

        model.expireFeedback(id: replacement.id)
        #expect(model.feedback == nil)

        model.showFeedback(.danmaku(true))
        model.clearFeedback()
        #expect(model.feedback == nil)
    }

    @Test
    func dismissedResumeNoticeDoesNotReturnUntilTheNoticeIsWithdrawn() {
        let model = PlayerOverlayModel()
        let notice = PlaybackResumeNotice(positionSeconds: 30, token: PlaybackResumeToken())
        var restartCount = 0

        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == notice)
        model.setResumeNotice(notice) { restartCount += 1 }
        model.restartFromBeginning()
        #expect(restartCount == 1)

        model.expireResumeNotice(token: PlaybackResumeToken())
        #expect(model.resumeNotice == notice)
        model.expireResumeNotice(token: notice.token)
        #expect(model.resumeNotice == nil)
        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == nil)

        let next = PlaybackResumeNotice(positionSeconds: 12, token: PlaybackResumeToken())
        model.setResumeNotice(next) {}
        #expect(model.resumeNotice == next)

        model.setResumeNotice(nil) {}
        #expect(model.resumeNotice == nil)
        model.setResumeNotice(notice) {}
        #expect(model.resumeNotice == notice)
    }

    @Test(arguments: [
        (30.4, true),
        (29.6, true),
        (30.6, false),
        (0, false),
        (Double.nan, false),
        (Double.infinity, false)
    ])
    func timeJumpAwayFromResumePositionDismissesTheNotice(
        seconds: Double,
        keepsNotice: Bool
    ) {
        let model = PlayerOverlayModel()
        let notice = PlaybackResumeNotice(positionSeconds: 30, token: PlaybackResumeToken())
        model.setResumeNotice(notice) {}

        model.observeTimeJump(toSeconds: seconds)

        #expect((model.resumeNotice == notice) == keepsNotice)
        model.setResumeNotice(notice) {}
        #expect((model.resumeNotice == notice) == keepsNotice)
    }

    /// 准备期间没有 item 时由浮层转圈；item 挂上后交给 AVKit 自己的转圈，两者不叠加。
    @Test(arguments: [
        (true, false, true),
        (true, true, false),
        (false, false, false),
        (false, true, false)
    ])
    func preparationActivityCoversOnlyThePreparationGapWithoutAnItem(
        isPreparing: Bool,
        hasCurrentItem: Bool,
        showsActivity: Bool
    ) {
        let model = PlayerOverlayModel()

        model.setPreparationActivity(isPreparing: isPreparing, hasCurrentItem: hasCurrentItem)

        #expect(model.showsPreparationActivity == showsActivity)
    }

    /// 只有开播后为减少卡顿而等待才算卡住；准备阶段、未就绪与短暂的缓冲评估都不算。
    @Test(arguments: [
        (
            false, true, AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate,
            AVPlayer.WaitingReason?.some(.toMinimizeStalls), true
        ),
        (false, true, .waitingToPlayAtSpecifiedRate, .evaluatingBufferingRate, false),
        (false, true, .waitingToPlayAtSpecifiedRate, nil, false),
        (false, true, .playing, nil, false),
        (false, true, .paused, nil, false),
        (true, true, .waitingToPlayAtSpecifiedRate, .toMinimizeStalls, false),
        (false, false, .waitingToPlayAtSpecifiedRate, .toMinimizeStalls, false)
    ])
    func stallCountsOnlyWaitingToMinimizeStallsAfterPlaybackIsReady(
        isPreparing: Bool,
        isItemReady: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus,
        reason: AVPlayer.WaitingReason?,
        isStalled: Bool
    ) {
        #expect(
            PlayerStallPolicy.isStalled(
                isPreparing: isPreparing,
                isItemReady: isItemReady,
                timeControlStatus: timeControlStatus,
                reasonForWaitingToPlay: reason
            ) == isStalled
        )
    }

    /// 卡住只在该次卡顿的延迟到期时仍未恢复才呈现；恢复立即撤下，恢复后再卡住重新计时。
    @Test
    func stallActivityAppearsOnlyForTheStallStillInProgress() throws {
        let model = PlayerOverlayModel()

        model.setStalled(true)
        let recovered = try #require(model.stallID)
        #expect(!model.showsStallActivity)
        model.setStalled(false)
        model.presentStall(id: recovered)
        #expect(!model.showsStallActivity)

        model.setStalled(true)
        let shown = try #require(model.stallID)
        model.presentStall(id: shown)
        #expect(model.showsStallActivity)

        model.setStalled(false)
        #expect(!model.showsStallActivity)
        model.setStalled(true)
        let restalled = try #require(model.stallID)
        #expect(restalled != shown)
        model.presentStall(id: shown)
        #expect(!model.showsStallActivity)
        model.presentStall(id: restalled)
        #expect(model.showsStallActivity)
    }

    @Test
    func overlayHostPassesThroughEverywhereExceptTheInteractiveFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let host = PassthroughHostingView(rootView: Color.clear)
        host.frame = container.bounds
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
        let nearTopLeading = NSPoint(x: 10, y: container.bounds.maxY - 10)
        let nearBottomLeading = NSPoint(x: 10, y: 10)

        #expect(host.hitTest(nearTopLeading) == nil)

        // 可交互区域使用 SwiftUI 的左上原点坐标。
        host.interactiveFrame = { CGRect(x: 0, y: 0, width: 200, height: 150) }
        #expect(host.hitTest(nearTopLeading) != nil)
        #expect(host.hitTest(nearBottomLeading) == nil)
    }
}
