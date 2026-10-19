import BiliApplication
import BiliModels
import Foundation
import QuartzCore
import Testing

@testable import BiliDanmaku

/// 固定静止时重新合成与速率切换的契约：速率立即生效；静止且一批改动之后只请求一次下一帧，
/// 走动中或不可见时不请求；没能合成的改动（被拒绝、没出帧、超时）保留到下次；stop 取消在途请求。
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DanmakuRecompositeTests {
    /// 有宿主时速率切换也立即按此刻生效，不等下一帧；切换本身不请求帧。
    @Test
    func playbackRateChangesTakeEffectImmediately() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler

        let before = renderer.rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        renderer.setPlaybackRate(0)
        let after = renderer.rootLayer.convertTime(CACurrentMediaTime(), from: nil)
        let frozen = renderer.rootLayer.convertTime(CACurrentMediaTime() + 5, from: nil)

        #expect(renderer.rootLayer.speed == 0)
        #expect(frozen >= before && frozen <= after)
        #expect(scheduler.requestCount == 0)

        renderer.setPlaybackRate(2)
        #expect(renderer.rootLayer.speed == 2)
        #expect(scheduler.requestCount == 0)
    }

    /// 静止时一批改动后只请求一次下一帧：同一轮再调用合并进在途请求，回调后没有新改动也不再请求。
    @Test
    func stillBatchRequestsTheNextFrameOnce() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler

        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()
        renderer.recompositeIfStill()
        #expect(scheduler.requestCount == 1)

        scheduler.fire()
        renderer.recompositeIfStill()
        #expect(scheduler.requestCount == 1)
        #expect(scheduler.pendingRequestCount == 0)
    }

    /// 走动中改动不请求帧：渲染服务器本来就在出帧。
    @Test
    func movingBatchDoesNotRequestAFrame() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler

        renderer.setPlaybackRate(2)
        renderer.recompositeIfStill()

        #expect(scheduler.requestCount == 0)
    }

    /// 宿主不可见时不接受请求，renderer 也不挂时限。
    @Test
    func invisibleHostAcceptsNoRequest() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        scheduler.acceptsRequests = false
        renderer.frameScheduler = scheduler

        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()

        #expect(scheduler.requestCount == 1)
        #expect(scheduler.pendingRequestCount == 0)
        #expect(scheduler.cancelCount == 0)
    }

    /// 宿主一直不回调（例如显示器休眠）时，renderer 到点取消请求，宿主释放 display link。
    @Test
    func unansweredRequestIsCancelledAfterTheTimeout() async {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler

        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()
        await scheduler.waitForCancel()
        renderer.recompositeIfStill()

        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.requestCount == 2)
        #expect(scheduler.pendingRequestCount == 1)
    }

    /// 不可见时被拒绝的改动保留：恢复可见后宿主再调用时请求一次。
    @Test
    func rejectedChangesAreRequestedAgainOnceVisible() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        scheduler.acceptsRequests = false
        renderer.frameScheduler = scheduler
        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()

        scheduler.acceptsRequests = true
        renderer.recompositeIfStill()
        renderer.recompositeIfStill()

        #expect(scheduler.requestCount == 2)
        #expect(scheduler.pendingRequestCount == 1)
    }

    /// 宿主没出帧就停了（以 false 回调）时改动保留，下次再请求。
    @Test
    func changesSurviveAFrameRequestStoppedWithoutDisplay() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler
        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()

        scheduler.cancelNextFrameRequests()
        renderer.recompositeIfStill()

        #expect(scheduler.requestCount == 2)
        #expect(scheduler.pendingRequestCount == 1)
    }

    /// 被拒绝后恢复播放：渲染服务器在出帧，恢复可见时不再请求。
    @Test
    func rejectedChangesAreDroppedOncePlaybackMoves() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        scheduler.acceptsRequests = false
        renderer.frameScheduler = scheduler
        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()

        scheduler.acceptsRequests = true
        renderer.setPlaybackRate(1)
        renderer.recompositeIfStill()

        #expect(scheduler.requestCount == 1)
    }

    /// 会话结束时取消在途帧请求，速率立即归零。
    @Test
    func stopCancelsTheFrameRequest() {
        let renderer = CoreAnimationDanmakuRenderer()
        let scheduler = ManualFrameScheduler()
        renderer.frameScheduler = scheduler
        renderer.setPlaybackRate(0)
        renderer.recompositeIfStill()

        renderer.stop()

        #expect(scheduler.cancelCount == 1)
        #expect(scheduler.pendingRequestCount == 0)
        #expect(renderer.rootLayer.speed == 0)
    }
}

/// 本 target 唯一的「下一显示帧」宿主替身：由测试逐帧触发，可设为不可见；记录请求与取消次数，
/// 取消时以 false 回调，与 App overlay 一致，测试可等到被取消。
@MainActor
final class ManualFrameScheduler: DanmakuFrameScheduling {
    var acceptsRequests = true
    private var handlers: [@MainActor (Bool) -> Void] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0
    private(set) var cancelCount = 0

    var pendingRequestCount: Int { handlers.count }

    func requestNextFrame(_ handler: @escaping @MainActor (Bool) -> Void) -> Bool {
        requestCount += 1
        guard acceptsRequests else { return false }
        handlers.append(handler)
        return true
    }

    func cancelNextFrameRequests() {
        cancelCount += 1
        deliver(didDisplay: false)
        let waiters = cancelWaiters
        cancelWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// 下一帧到了：回调当前全部请求；回调里新发的请求留到下一次。
    func fire() {
        deliver(didDisplay: true)
    }

    func waitForCancel() async {
        guard cancelCount == 0 else { return }
        await withCheckedContinuation { continuation in
            cancelWaiters.append(continuation)
        }
    }

    private func deliver(didDisplay: Bool) {
        let pending = handlers
        handlers.removeAll()
        for handler in pending {
            handler(didDisplay)
        }
    }
}
