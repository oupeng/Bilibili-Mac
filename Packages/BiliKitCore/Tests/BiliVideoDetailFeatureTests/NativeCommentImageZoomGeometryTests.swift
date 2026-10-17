import CoreGraphics
import Testing

@testable import BiliVideoDetailFeature

/// 评论图片预览按比例适配可视区，单击在适配与放大之间切换，超过阈值的移动算拖动而不算单击。
struct NativeCommentImageZoomGeometryTests {
    /// 图片按比例缩进可视区；缩小图与原图只差取整误差（如 358×360 与 719×724 相差 1pt），换图后缩放位置基本不变。
    @Test(arguments: [
        (
            CGSize(width: 600, height: 1200), CGSize(width: 800, height: 600),
            CGSize(width: 300, height: 600)
        ),
        (
            CGSize(width: 2276, height: 1280), CGSize(width: 800, height: 600),
            CGSize(width: 800, height: 449)
        ),
        (
            CGSize(width: 358, height: 360), CGSize(width: 800, height: 600),
            CGSize(width: 596, height: 600)
        ),
        (
            CGSize(width: 719, height: 724), CGSize(width: 800, height: 600),
            CGSize(width: 595, height: 600)
        )
    ])
    func imageFitsInsideTheViewport(image: CGSize, viewport: CGSize, fitted: CGSize) {
        #expect(NativeCommentImageZoomGeometry.fittedSize(imageSize: image, in: viewport) == fitted)
    }

    @Test(arguments: [CGSize.zero, CGSize(width: 0, height: 10)])
    func degenerateSizesFitToNothing(size: CGSize) {
        #expect(
            NativeCommentImageZoomGeometry.fittedSize(
                imageSize: size,
                in: CGSize(width: 800, height: 600)
            ) == .zero
        )
        #expect(
            NativeCommentImageZoomGeometry.fittedSize(
                imageSize: CGSize(width: 800, height: 600),
                in: size
            ) == .zero
        )
    }

    /// 单击图片在适配与放大之间切换；双指缩放到任意倍率后单击都回到适配。
    @Test(
        arguments: [
            (CGFloat(1), NativeCommentImageZoomGeometry.clickMagnification),
            (1.005, NativeCommentImageZoomGeometry.clickMagnification),
            (NativeCommentImageZoomGeometry.clickMagnification, 1),
            (1.4, 1),
            (NativeCommentImageZoomGeometry.maximumMagnification, 1)
        ] as [(CGFloat, CGFloat)]
    )
    func clickTogglesBetweenFitAndZoom(current: CGFloat, next: CGFloat) {
        #expect(NativeCommentImageZoomGeometry.magnificationAfterClick(from: current) == next)
    }

    /// 按下后移动超过阈值才算拖动；拖动后松开不再当作单击（不缩放、不关闭）。
    @Test(
        arguments: [
            (CGPoint(x: 10, y: 10), false),
            (CGPoint(x: 12, y: 12), false),
            (CGPoint(x: 13, y: 10), false),
            (CGPoint(x: 14, y: 10), true),
            (CGPoint(x: 10, y: 60), true)
        ] as [(CGPoint, Bool)]
    )
    func movementBeyondTheThresholdIsADrag(end: CGPoint, isDrag: Bool) {
        #expect(
            NativeCommentImageZoomGeometry.isDrag(from: CGPoint(x: 10, y: 10), to: end) == isDrag
        )
    }
}
