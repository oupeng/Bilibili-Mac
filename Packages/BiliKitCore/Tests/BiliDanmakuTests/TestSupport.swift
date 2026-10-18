import BiliApplication
import BiliModels
import Foundation
import Testing

@testable import BiliDanmaku

/// 本 target 共用的弹幕：时间点固定为 1 秒，文字覆盖多种文字系统与 emoji。
func fixtureEvent(
    id: String,
    mode: DanmakuPresentationMode,
    colorRGB: UInt32 = 0xFFFFFF,
    fontSize: Double = 24
) -> DanmakuEvent {
    DanmakuEvent(
        id: id,
        timeSeconds: 1,
        mode: mode,
        text: "中文 日本語 한국어 Latin 😀 #",
        fontSize: fontSize,
        colorRGB: colorRGB,
        colorStyle: .solid,
        weight: 1
    )
}
