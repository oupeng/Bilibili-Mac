import BiliApplication
import Foundation
import Testing

@testable import BiliKit

/// 「播放结束后」：偏好只认已知值、缺失或损坏时回退不循环；播完的处理只在同一 item 刚进入结束时触发一次，
/// 订阅当下已经结束、重复发布结束都不触发，换了 item 的结束照常触发；停止观察后不再处理。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PlayerPlaybackEndTests {
    @Test
    func behaviorPreferenceFallsBackToStop() {
        withIsolatedDefaults { defaults in
            let store = PlaybackEndBehaviorStore(defaults: defaults)
            #expect(store.behavior == .stop)
            store.behavior = .repeatOne
            #expect(PlaybackEndBehaviorStore(defaults: defaults).behavior == .repeatOne)
            defaults.set("loop-forever", forKey: "player.endBehavior")
            #expect(store.behavior == .stop)
            defaults.set(1, forKey: "player.endBehavior")
            #expect(store.behavior == .stop)
        }
    }

    @Test
    func handlingFiresOnceWhenTheItemEntersTheEnd() async {
        let timeline = ManualTimeline()
        let handled = HandledEnds()
        let observer = PlayerPlaybackEndObserver()
        let first = PlaybackLoadIntent()
        timeline.current = snapshot(first, .ended)
        observer.start(
            PlayerPlaybackEndActions(
                observeTimeline: timeline.observe,
                handleEnded: { snapshot in
                    handled.snapshots.append(snapshot)
                    return .endBehavior(.repeatOne)
                }
            ),
            present: { handled.feedback.append($0) }
        )

        timeline.send(snapshot(first, .ended))
        timeline.send(snapshot(first, .playing))
        timeline.send(snapshot(first, .ended))
        await waitForObservedState { handled.feedback.count == 1 }
        timeline.send(snapshot(first, .ended))
        let second = PlaybackLoadIntent()
        timeline.send(snapshot(second, .ended))
        await waitForObservedState { handled.feedback.count == 2 }
        #expect(handled.snapshots.map(\.loadIntent) == [first, second])

        observer.stop()
        timeline.send(snapshot(second, .playing))
        timeline.send(snapshot(second, .ended))
        #expect(handled.snapshots.count == 2)
        #expect(timeline.observers.isEmpty)
    }

    private func snapshot(
        _ intent: PlaybackLoadIntent,
        _ state: PlaybackTimelineState
    ) -> PlaybackTimelineSnapshot {
        PlaybackTimelineSnapshot(
            identity: PlaybackItemIdentity(bvid: "BV1EndFixture", cid: 1),
            positionSeconds: 0,
            durationSeconds: 60,
            rate: 0,
            state: state,
            discontinuityGeneration: 0,
            loadIntent: intent
        )
    }
}

/// 手动推进的时间线：订阅时先补发当前快照，与真实时间线的 `observe` 一致。
@MainActor
private final class ManualTimeline {
    var current = PlaybackTimelineSnapshot.idle
    private(set) var observers: [UUID: @MainActor (PlaybackTimelineSnapshot) -> Void] = [:]

    func observe(
        _ observer: @escaping @MainActor (PlaybackTimelineSnapshot) -> Void
    ) -> @MainActor @Sendable () -> Void {
        let id = UUID()
        observers[id] = observer
        observer(current)
        return { [weak self] in self?.observers[id] = nil }
    }

    func send(_ snapshot: PlaybackTimelineSnapshot) {
        current = snapshot
        for observer in observers.values { observer(snapshot) }
    }
}

@MainActor
@Observable
private final class HandledEnds {
    var snapshots: [PlaybackTimelineSnapshot] = []
    var feedback: [PlayerActionFeedback] = []
}
