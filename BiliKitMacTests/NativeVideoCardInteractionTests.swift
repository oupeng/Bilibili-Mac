import AppKit
import Testing

@testable import BiliKit

struct NativeVideoCardInteractionTests {
    /// 悬停描边按卡片自己的外观解析，不受当时绘制外观影响；卡片换主题后描边跟着换。
    @Test @MainActor
    func hoverStrokeFollowsTheCardAppearanceAcrossThemeChanges() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        func stroke(in appearance: NSAppearance) -> CGColor {
            var color = NSColor.secondaryLabelColor.cgColor
            appearance.performAsCurrentDrawingAppearance {
                color = NSColor.secondaryLabelColor.cgColor
            }
            return color
        }
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))
        card.appearance = dark

        light.performAsCurrentDrawingAppearance {
            card.setHovered(true)
        }
        #expect(card.layer?.borderColor == stroke(in: dark))

        light.performAsCurrentDrawingAppearance {
            card.appearance = light
        }
        #expect(card.layer?.borderColor == stroke(in: light))

        dark.performAsCurrentDrawingAppearance {
            card.appearance = dark
        }
        #expect(card.layer?.borderColor == stroke(in: dark))
    }
}
