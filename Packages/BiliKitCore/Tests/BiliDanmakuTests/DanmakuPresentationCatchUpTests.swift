import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 固定补位批次的呈现契约：按各自时间点准入并从已走过的位置开始，同批一起上屏，
/// 取消时归还车道，候选只准备车道容纳得下的最新几条。
@MainActor
@Suite
struct DanmakuPresentationCatchUpTests {
    /// 补位：每条按自己的时间点准入并从已走过的位置开始；准备期间已走完的、窗口外的都不显示。
    @Test
    func catchUpBatchAdmitsAtEventTimeAndSkipsFinishedDanmaku() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CatchUpFixture", cid: 1)
        // 800pt 画面、120pt 文字的滚动弹幕约 6.8 秒走完；回看窗口约 9.8 秒；顶部弹幕 4 秒。
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "outside-window", time: 80),
                    timedEvent(id: "finished", time: 91),
                    timedEvent(id: "mid-way", time: 95),
                    timedEvent(id: "top", time: 97, mode: .top),
                    timedEvent(id: "just-entered", time: 99.5)
                ],
                catchesUp: true
            )
        )

        #expect(backend.renderedEventIDs == ["mid-way", "top", "just-entered"])
        #expect(backend.renderedPlacements.map(\.admittedAtSeconds) == [95, 97, 99.5])
        #expect(backend.renderedElapsedSeconds == [5, 3, 0.5])
        #expect(controller.statistics.droppedCapacity == 0)
    }

    /// 纹理准备乱序完成时，补位弹幕仍按时间先后准入，车道按连续播放时的位置计算。
    @Test
    func catchUpAdmissionStaysInTimeOrderWhenPreparationsFinishOutOfOrder() throws {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1OrderCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "earlier", time: 96),
                    timedEvent(id: "later", time: 98)
                ],
                catchesUp: true
            )
        )
        let first = try #require(backend.preparationIDs.first)
        let second = try #require(backend.preparationIDs.last)

        backend.completePreparation(second)
        #expect(backend.renderedEventIDs.isEmpty)
        backend.completePreparation(first)

        #expect(backend.renderedEventIDs == ["earlier", "later"])
        #expect(backend.renderedPlacements.map(\.admittedAtSeconds) == [96, 98])
    }

    /// 同批补位弹幕等全部纹理准备好后一起上屏，已走过的时长按上屏时刻计算，不会从左到右逐条出现。
    @Test
    func catchUpBatchAppearsTogetherOnceEveryTextureIsReady() throws {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1TogetherCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "first", time: 96),
                    timedEvent(id: "second", time: 97),
                    timedEvent(id: "third", time: 98)
                ],
                catchesUp: true
            )
        )
        #expect(backend.preparationIDs.count == 3)

        backend.completePreparation(backend.preparationIDs[0])
        backend.completePreparation(backend.preparationIDs[1])
        #expect(backend.renderedEventIDs.isEmpty)
        controller.apply(update(identity: identity, position: 100.5, generation: 1))
        backend.completePreparation(backend.preparationIDs[2])

        #expect(backend.renderedEventIDs == ["first", "second", "third"])
        #expect(backend.renderedElapsedSeconds == [4.5, 3.5, 2.5])
    }

    /// 等待一起上屏的补位弹幕被取消时归还车道，后来的弹幕仍能用同一条车道。
    @Test
    func cancelledCatchUpReleasesItsReservedLanes() {
        let backend = RecordingRenderingBackend()
        backend.delaysPreparation = true
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20)
        )
        let owner = UUID()
        controller.attachSurface(ownerID: owner)
        let identity = PlaybackItemIdentity(bvid: "BV1ReleaseCatchUp", cid: 1)
        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: [
                    timedEvent(id: "waiting", time: 99, mode: .top),
                    timedEvent(id: "unfinished", time: 99.5, mode: .top)
                ],
                catchesUp: true
            )
        )
        backend.completePreparation(backend.preparationIDs[0])
        #expect(backend.renderedEventIDs.isEmpty)

        controller.updateSurface(width: 800, height: 300, backingScale: 3, ownerID: owner)
        backend.delaysPreparation = false
        controller.apply(
            update(
                identity: identity,
                position: 100.2,
                generation: 1,
                events: [timedEvent(id: "later", time: 100.2, mode: .top)]
            )
        )

        #expect(backend.renderedEventIDs == ["later"])
        #expect(backend.renderedPlacements.map(\.laneIndex) == [0])
        #expect(controller.statistics.active == 1)
    }

    /// 补位候选超过车道能容纳的数量时只准备最新的，其余计为容量丢弃。
    @Test
    func catchUpPreparesOnlyTheNewestCandidatesTheLanesCanHold() {
        let backend = RecordingRenderingBackend()
        let controller = DanmakuPresentationController(
            backend: backend,
            configuration: configuration(maximumActiveCount: 20, surfaceHeight: 30)
        )
        let identity = PlaybackItemIdentity(bvid: "BV1CapCatchUp", cid: 1)
        let limit = DanmakuPresentationController.catchUpCandidatesPerLane
        let events = (0..<(limit + 2)).map {
            timedEvent(id: "candidate-\($0)", time: 99 + Double($0) * 0.1, mode: .top)
        }

        controller.apply(
            update(
                identity: identity,
                position: 100,
                generation: 1,
                events: events,
                catchesUp: true
            )
        )

        #expect(backend.preparationIDs.count == limit)
        #expect(controller.statistics.droppedCapacity >= 2)
        #expect(!backend.renderedEventIDs.contains("candidate-0"))
        #expect(!backend.renderedEventIDs.contains("candidate-1"))
    }
}
