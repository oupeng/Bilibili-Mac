import AppKit
import Testing

@testable import BiliKit
@testable import BiliVideoDetailFeature

struct NativeClickRegionTests {
    /// 只在给出的区域内开始单击；空区域被忽略，区域清空后整块不可点。
    @Test @MainActor
    func clickBeginsOnlyInsideTheGivenRects() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        let region = NativeClickRegion()
        region.attach(to: host) {}
        let click = LocatedClickRecognizer()
        region.setRects([
            NSRect(x: 0, y: 0, width: 32, height: 32),
            NSRect(x: 44, y: 0, width: 80, height: 20),
            .zero
        ])

        click.location = NSPoint(x: 10, y: 10)
        #expect(region.gestureRecognizerShouldBegin(click))
        click.location = NSPoint(x: 60, y: 10)
        #expect(region.gestureRecognizerShouldBegin(click))
        click.location = NSPoint(x: 200, y: 40)
        #expect(!region.gestureRecognizerShouldBegin(click))
        #expect(region.rects.count == 2)

        region.setRects([])
        click.location = NSPoint(x: 10, y: 10)
        #expect(!region.gestureRecognizerShouldBegin(click))
    }
}

/// 位置可控的单击手势：只用来驱动区域判定，不模拟事件。
@MainActor
private final class LocatedClickRecognizer: NSClickGestureRecognizer {
    var location = NSPoint.zero

    override func location(in view: NSView?) -> NSPoint {
        location
    }
}
