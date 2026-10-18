import AppKit
import BiliUI
import Testing

@testable import BiliVideoCollectionUI

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

    /// 选中卡片的读屏值取自 BiliUI 字符串目录里“已选择”的译文，取消选中后清空。
    @Test @MainActor
    func selectedCardAnnouncesTheBiliUISelectedValue() {
        let card = NativeVideoCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 220))

        card.setSelected(true)
        let value = card.accessibilityValue() as? String
        #expect(value == VideoCardAccessibilityText.selectedValue)
        #expect(["已选择", "已選擇", "選択済み", "Selected"].contains(value ?? ""))

        card.setSelected(false)
        #expect(card.accessibilityValue() == nil)
    }
}
