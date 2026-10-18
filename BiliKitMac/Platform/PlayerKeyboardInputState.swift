import Foundation

/// 播放器方向键：左右短按跳转 5 秒、长按临时倍速（左 0.5 倍、右 2 倍），上下按 5% 调音量。
enum PlayerKeyboardDirection: Equatable, Hashable, Sendable {
    case left
    case right
    case up
    case down

    var momentaryRate: PlayerMomentaryRate? {
        switch self {
        case .left: .slow
        case .right: .fast
        case .up, .down: nil
        }
    }

    var seekOffsetSeconds: Double? {
        switch self {
        case .left: -5
        case .right: 5
        case .up, .down: nil
        }
    }

    var volumeOffset: Float? {
        switch self {
        case .up: 0.05
        case .down: -0.05
        case .left, .right: nil
        }
    }
}

/// 播放器的离散快捷键：播放／暂停、弹幕、字幕与全屏；按键映射在
/// `PlayerKeyboardShortcutController`。
enum PlayerKeyboardShortcut: Equatable, Hashable, Sendable {
    case playback
    case danmaku
    case subtitles
    case fullScreen
}

/// 播放器键盘输入的纯状态机：把按下、抬起与长按到时转成动作，由 `PlayerKeyboardShortcutController`
/// 执行。
///
/// 长按计时 Task 由 controller 持有。左右键同时只跟踪一个按压，`pressID` 在每次新按压时生成，
/// 长按到时（`deadlineReached`）与结束都按它比对，不符的迟到事件丢弃。`cancel()`（失焦、禁用、
/// 输入框取得焦点）时仍按住的键记入 suppressed 集合：其后的系统重复事件被忽略，
/// 直到松开或一次新的非重复按下，避免取消后同一次按住又触发。
struct PlayerKeyboardInputState: Equatable, Sendable {
    /// 按住超过这么久才算长按并开始临时倍速，之前松开算短按跳转。
    ///
    /// 调大让临时倍速更迟生效，调小容易把稍慢的点按误判为长按。
    static let longPressDelay: TimeInterval = 0.35
    /// 按住音量键时系统重复事件的最短生效间隔，每秒最多约 12 步。
    ///
    /// 调小音量变化更快、更难停在想要的值，调大则变化更慢。
    static let minimumVolumeRepeatInterval: TimeInterval = 0.08

    /// 状态机交给 controller 执行的动作；长按相关动作都带 `pressID`，
    /// 执行方据此忽略过期的计时与结束。
    enum Action: Equatable, Sendable {
        case scheduleLongPress(pressID: UUID)
        case cancelLongPress(pressID: UUID)
        case beginMomentaryRate(rate: PlayerMomentaryRate, pressID: UUID)
        case endMomentaryRate(pressID: UUID)
        case seekBy(seconds: Double)
        case adjustVolume(by: Float)
        case togglePlayback
        case toggleDanmaku
        case toggleSubtitles
        case toggleFullScreen
    }

    /// 当前跟踪的左右键按压：方向、`pressID` 与阶段（等待长按到时，或已进入临时倍速）。
    private struct HorizontalPress: Equatable, Sendable {
        enum Phase: Equatable, Sendable {
            case waitingForDeadline
            case longActivated
        }

        let direction: PlayerKeyboardDirection
        let pressID: UUID
        var phase: Phase
    }

    private var horizontalPress: HorizontalPress?
    private var suppressedHorizontalKeys: Set<PlayerKeyboardDirection> = []
    private var heldVolumeKeys: Set<PlayerKeyboardDirection> = []
    private var suppressedVolumeKeys: Set<PlayerKeyboardDirection> = []
    private var lastVolumeStepTime: [PlayerKeyboardDirection: TimeInterval] = [:]
    private var heldShortcuts: Set<PlayerKeyboardShortcut> = []
    private var suppressedShortcuts: Set<PlayerKeyboardShortcut> = []

    mutating func keyDown(
        _ direction: PlayerKeyboardDirection,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> [Action] {
        if let volumeOffset = direction.volumeOffset {
            return volumeKeyDown(
                direction,
                offset: volumeOffset,
                isRepeat: isRepeat,
                timestamp: timestamp
            )
        }

        if suppressedHorizontalKeys.contains(direction) {
            guard !isRepeat else { return [] }
            suppressedHorizontalKeys.remove(direction)
        }
        if horizontalPress?.direction == direction {
            return []
        }
        guard !isRepeat else { return [] }

        var actions = cancelHorizontalPress(suppressHeldKey: true)
        let pressID = UUID()
        horizontalPress = HorizontalPress(
            direction: direction,
            pressID: pressID,
            phase: .waitingForDeadline
        )
        actions.append(.scheduleLongPress(pressID: pressID))
        return actions
    }

    mutating func keyUp(_ direction: PlayerKeyboardDirection) -> [Action] {
        if direction.volumeOffset != nil {
            heldVolumeKeys.remove(direction)
            suppressedVolumeKeys.remove(direction)
            lastVolumeStepTime[direction] = nil
            return []
        }
        if suppressedHorizontalKeys.remove(direction) != nil {
            return []
        }
        guard let horizontalPress,
            horizontalPress.direction == direction
        else { return [] }
        self.horizontalPress = nil
        switch horizontalPress.phase {
        case .waitingForDeadline:
            guard let offset = direction.seekOffsetSeconds else { return [] }
            return [
                .cancelLongPress(pressID: horizontalPress.pressID),
                .seekBy(seconds: offset)
            ]
        case .longActivated:
            return [.endMomentaryRate(pressID: horizontalPress.pressID)]
        }
    }

    mutating func deadlineReached(pressID: UUID) -> [Action] {
        guard var horizontalPress,
            horizontalPress.pressID == pressID,
            horizontalPress.phase == .waitingForDeadline,
            let rate = horizontalPress.direction.momentaryRate
        else { return [] }
        horizontalPress.phase = .longActivated
        self.horizontalPress = horizontalPress
        return [.beginMomentaryRate(rate: rate, pressID: pressID)]
    }

    mutating func shortcutKeyDown(
        _ shortcut: PlayerKeyboardShortcut,
        isRepeat: Bool
    ) -> [Action] {
        if suppressedShortcuts.contains(shortcut) {
            guard !isRepeat else { return [] }
            suppressedShortcuts.remove(shortcut)
        }
        guard !isRepeat, heldShortcuts.insert(shortcut).inserted else {
            return []
        }
        return switch shortcut {
        case .playback: [.togglePlayback]
        case .danmaku: [.toggleDanmaku]
        case .subtitles: [.toggleSubtitles]
        case .fullScreen: [.toggleFullScreen]
        }
    }

    mutating func shortcutKeyUp(_ shortcut: PlayerKeyboardShortcut) -> [Action] {
        heldShortcuts.remove(shortcut)
        suppressedShortcuts.remove(shortcut)
        return []
    }

    mutating func cancel() -> [Action] {
        suppressedVolumeKeys.formUnion(heldVolumeKeys)
        heldVolumeKeys.removeAll(keepingCapacity: true)
        lastVolumeStepTime.removeAll(keepingCapacity: true)
        suppressedShortcuts.formUnion(heldShortcuts)
        heldShortcuts.removeAll(keepingCapacity: true)
        return cancelHorizontalPress(suppressHeldKey: true)
    }

    private mutating func volumeKeyDown(
        _ direction: PlayerKeyboardDirection,
        offset: Float,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> [Action] {
        if suppressedVolumeKeys.contains(direction) {
            guard !isRepeat else { return [] }
            suppressedVolumeKeys.remove(direction)
        }
        heldVolumeKeys.insert(direction)
        if isRepeat,
            let previous = lastVolumeStepTime[direction],
            timestamp - previous < Self.minimumVolumeRepeatInterval
        {
            return []
        }
        lastVolumeStepTime[direction] = timestamp
        return [.adjustVolume(by: offset)]
    }

    private mutating func cancelHorizontalPress(
        suppressHeldKey: Bool
    ) -> [Action] {
        guard let horizontalPress else { return [] }
        self.horizontalPress = nil
        if suppressHeldKey {
            suppressedHorizontalKeys.insert(horizontalPress.direction)
        }
        switch horizontalPress.phase {
        case .waitingForDeadline:
            return [.cancelLongPress(pressID: horizontalPress.pressID)]
        case .longActivated:
            return [.endMomentaryRate(pressID: horizontalPress.pressID)]
        }
    }
}

/// 播放器是否接管一个按键事件的判定。
///
/// 快捷键启用、没有 ⌘⌃⌥⇧ 修饰键、事件来自锚点所在窗口，且焦点不在拿走按键的响应者（可编辑文本、
/// `PlayerKeyboardFocusOwner` 浮层）上时才接管。
enum PlayerKeyboardEventScope {
    static func captures(
        isEnabled: Bool,
        hasDisallowedModifier: Bool,
        eventMatchesCaptureWindow: Bool,
        focusedResponderOwnsKeys: Bool
    ) -> Bool {
        isEnabled
            && !hasDisallowedModifier
            && eventMatchesCaptureWindow
            && !focusedResponderOwnsKeys
    }
}
