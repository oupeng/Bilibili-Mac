import AVFoundation
import Testing

@testable import BiliKit

/// 每次 seek 只记一次（便捷入口不重复计数），完成回调后不再在途。
@MainActor
struct SeekTrackingPlayerTests {
    @Test
    func everySeekCountsOnceAndSettlesOnCompletion() async {
        let player = SeekTrackingPlayer()

        await withCheckedContinuation { continuation in
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                continuation.resume()
            }
        }
        #expect(player.seekActivity.generation == 1)
        #expect(!player.seekActivity.hasPendingSeek)

        await withCheckedContinuation { continuation in
            player.seek(to: .zero) { _ in
                continuation.resume()
            }
        }
        #expect(player.seekActivity.generation == 2)
        #expect(!player.seekActivity.hasPendingSeek)
    }
}
