import Testing

@testable import BiliApplication

/// 播完时：不循环停下，单集循环重播；充电试看片段播完一律停下。
struct PlaybackEndPolicyTests {
    @Test
    func behaviorDecidesUnlessThePreviewEnded() {
        let preview = PlaybackAccessNotice.upowerPreview(
            previewDurationSeconds: 60,
            fullDurationSeconds: 600
        )
        #expect(PlaybackEndPolicy.action(behavior: .stop, accessNotice: nil) == .none)
        #expect(PlaybackEndPolicy.action(behavior: .repeatOne, accessNotice: nil) == .replay)
        #expect(
            PlaybackEndPolicy.action(behavior: .repeatOne, accessNotice: .upowerExclusive)
                == .replay
        )
        #expect(PlaybackEndPolicy.action(behavior: .repeatOne, accessNotice: preview) == .none)
        #expect(PlaybackEndBehavior.defaultValue == .stop)
    }
}
