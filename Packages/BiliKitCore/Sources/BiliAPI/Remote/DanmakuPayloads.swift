import BiliModels
import Foundation
import SwiftProtobuf

enum DanmakuPayloadDecoder {
    private static let maximumEventCount = 20_000
    private static let maximumTextLength = 1_000_000
    private static let maximumEventTextLength = 4_096
    private static let maximumTimeMilliseconds = 86_400_000
    private static let baseColorRGBMask: UInt32 = 0x00FF_FFFF
    /// 字段 24 `colorful` 里大会员渐变弹幕的类型号。
    private static let vipGradientColorfulType: Int32 = 60_001

    static func events(from data: Data) throws -> [DanmakuEvent] {
        let payload: Bilikit_Danmaku_SegmentReply
        do {
            payload = try Bilikit_Danmaku_SegmentReply(serializedBytes: data)
        } catch {
            throw BiliAPIError.invalidDanmakuData
        }
        guard payload.elements.count <= maximumEventCount else {
            throw BiliAPIError.invalidDanmakuData
        }

        var totalTextLength = 0
        return try payload.elements.compactMap { element in
            guard let mode = presentationMode(element.mode) else {
                return nil
            }
            let text = element.content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !text.isEmpty else {
                return nil
            }
            let id =
                element.idString.isEmpty
                ? (element.id > 0 ? String(element.id) : nil)
                : element.idString
            guard let id,
                id.count <= 128,
                element.progressMilliseconds >= 0,
                element.progressMilliseconds <= maximumTimeMilliseconds,
                text.count <= maximumEventTextLength
            else {
                throw BiliAPIError.invalidDanmakuData
            }
            totalTextLength += text.count
            guard totalTextLength <= maximumTextLength else {
                throw BiliAPIError.invalidDanmakuData
            }
            return DanmakuEvent(
                id: id,
                timeSeconds: Double(element.progressMilliseconds) / 1_000,
                mode: mode,
                text: text,
                fontSize: normalizedFontSize(element.fontSize),
                // Field 5 supplies the base RRGGBB color; the member gradient comes from
                // field 24 and stays a separate style instead of being packed into RGB.
                colorRGB: element.colorRgb & baseColorRGBMask,
                colorStyle: colorStyle(element.colorful),
                weight: Int(element.weight)
            )
        }
    }

    private static func presentationMode(
        _ value: Int32
    ) -> DanmakuPresentationMode? {
        switch value {
        case 1, 2, 3:
            .scrolling
        case 4:
            .bottom
        case 5:
            .top
        default:
            nil
        }
    }

    /// 只认大会员渐变（60001）；其他或将来新增的彩色类型按普通弹幕显示。
    private static func colorStyle(_ value: Int32) -> DanmakuColorStyle {
        value == vipGradientColorfulType ? .vipGradient : .solid
    }

    private static func normalizedFontSize(_ value: Int32) -> Double {
        switch value {
        case 18, 25, 36:
            Double(value)
        default:
            25
        }
    }
}
