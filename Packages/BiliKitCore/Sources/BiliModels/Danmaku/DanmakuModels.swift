public enum DanmakuPresentationMode: Sendable, Hashable {
    case scrolling
    case top
    case bottom
}

/// 弹幕的着色样式。
public enum DanmakuColorStyle: Sendable, Hashable {
    /// 按 `colorRGB` 填充，描边按字色自动取深或浅。
    case solid
    /// 大会员彩色弹幕：白色填充、横向渐变描边，不使用 `colorRGB`。
    case vipGradient
}

public struct DanmakuEvent: Sendable, Hashable, Identifiable {
    public let id: String
    public let timeSeconds: Double
    public let mode: DanmakuPresentationMode
    public let text: String
    public let fontSize: Double
    public let colorRGB: UInt32
    public let colorStyle: DanmakuColorStyle
    public let weight: Int

    public init(
        id: String,
        timeSeconds: Double,
        mode: DanmakuPresentationMode,
        text: String,
        fontSize: Double,
        colorRGB: UInt32,
        colorStyle: DanmakuColorStyle,
        weight: Int
    ) {
        self.id = id
        self.timeSeconds = timeSeconds
        self.mode = mode
        self.text = text
        self.fontSize = fontSize
        self.colorRGB = colorRGB
        self.colorStyle = colorStyle
        self.weight = weight
    }
}

extension DanmakuEvent: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "DanmakuEvent(redacted)" }
    public var debugDescription: String { description }
}

public struct DanmakuSegment: Sendable, Equatable {
    public let index: Int
    public let events: [DanmakuEvent]

    public init(index: Int, events: [DanmakuEvent]) {
        self.index = index
        self.events = events
    }
}
