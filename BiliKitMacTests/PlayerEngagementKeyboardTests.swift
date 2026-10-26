import Foundation
import Testing

@testable import BiliKit

/// 点赞键 Q 的短按、长按三连与取消，以及 W、E 两个离散快捷键。
///
/// 没到 `longPressDelay` 就松开是点赞或取消（在松开时执行）；按住到 `longPressDelay` 显示三连进度，到
/// `tripleHoldDuration` 三连，进度出现后、三连之前松开什么都不做；系统重复与取消后的残留按住不再触发。W、E 按下即执行。
struct PlayerEngagementKeyboardTests {
    @Test
    func shortPressLikesOnKeyUp() throws {
        var state = PlayerKeyboardInputState()
        let pressID = try likePressID(state.likeKeyDown(isRepeat: false))

        #expect(state.likeKeyDown(isRepeat: true).isEmpty)
        #expect(state.likeKeyUp() == [.cancelLikeHold(pressID: pressID), .toggleLike])
        #expect(state.likeProgressDeadlineReached(pressID: pressID).isEmpty)
    }

    @Test
    func holdingShowsProgressThenTriples() throws {
        var state = PlayerKeyboardInputState()
        let pressID = try likePressID(state.likeKeyDown(isRepeat: false))

        #expect(
            state.likeProgressDeadlineReached(pressID: pressID) == [
                .beginTripleProgress(pressID: pressID)
            ]
        )
        #expect(
            state.likeTripleDeadlineReached(pressID: pressID) == [
                .endTripleProgress(pressID: pressID), .triple
            ]
        )
        #expect(state.likeKeyUp().isEmpty)
    }

    @Test
    func releasingAfterTheProgressAppearsDoesNothing() throws {
        var state = PlayerKeyboardInputState()
        let pressID = try likePressID(state.likeKeyDown(isRepeat: false))
        _ = state.likeProgressDeadlineReached(pressID: pressID)

        #expect(
            state.likeKeyUp() == [
                .cancelLikeHold(pressID: pressID), .endTripleProgress(pressID: pressID)
            ]
        )
        #expect(state.likeTripleDeadlineReached(pressID: pressID).isEmpty)
    }

    /// 取消（失焦、禁用、输入框取得焦点）时不点赞也不三连；仍按住的 Q 的系统重复不再开始新的按压。
    @Test
    func cancellationDropsTheHoldAndSuppressesRepeats() throws {
        var state = PlayerKeyboardInputState()
        let pressID = try likePressID(state.likeKeyDown(isRepeat: false))
        _ = state.likeProgressDeadlineReached(pressID: pressID)

        #expect(
            state.cancel() == [
                .cancelLikeHold(pressID: pressID), .endTripleProgress(pressID: pressID)
            ]
        )
        #expect(state.likeKeyDown(isRepeat: true).isEmpty)
        #expect(state.likeTripleDeadlineReached(pressID: pressID).isEmpty)
        #expect(state.likeKeyUp().isEmpty)
        #expect(try likePressID(state.likeKeyDown(isRepeat: false)) != pressID)
    }

    @Test
    func coinAndFavoriteFireOnceOnKeyDown() {
        var state = PlayerKeyboardInputState()

        #expect(state.shortcutKeyDown(.coin, isRepeat: false) == [.openCoinPanel])
        #expect(state.shortcutKeyDown(.coin, isRepeat: true).isEmpty)
        #expect(state.shortcutKeyDown(.favorite, isRepeat: false) == [.chooseFavoriteFolders])
    }

    private func likePressID(_ actions: [PlayerKeyboardInputState.Action]) throws -> UUID {
        guard actions.count == 1, case .scheduleLikeHold(let pressID) = actions[0] else {
            Issue.record("expected one scheduled like hold, got \(actions)")
            throw LikePressMissing()
        }
        return pressID
    }

    private struct LikePressMissing: Error {}
}
