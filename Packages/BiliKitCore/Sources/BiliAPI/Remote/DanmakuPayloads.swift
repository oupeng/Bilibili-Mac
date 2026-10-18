import BiliModels
import Foundation
import SwiftProtobuf

/// 把弹幕分段 protobuf（`/x/v2/dm/wbi/web/seg.so`）解码为 `DanmakuEvent`，由
/// `BiliDanmakuRepository` 调用。
///
/// 调用前响应已在 `BiliAPIClient` 通过 Content-Type、非 JSON／HTML 与 2 MiB 上限检查（见
/// SECURITY-MODEL §4）。事件数或文字总量超限、单条 ID／时间点／文字越界时整段按无效数据失败；
/// 不认识的展示模式与空白文字只跳过该条。见 docs/ARCHITECTURE.md「弹幕」。
enum DanmakuPayloadDecoder {
    /// 单个分段的事件数上限，超出整段失败；调小会让密集分段整段丢失，调大放宽单段的内存占用上限。
    private static let maximumEventCount = 20_000
    /// 单个分段所有弹幕文字的字符总数上限，超出整段失败；与事件数上限一起约束单段的内存占用。
    private static let maximumTextLength = 1_000_000
    /// 单条弹幕文字的字符数上限，超出整段失败。
    private static let maximumEventTextLength = 4_096
    /// 弹幕时间点上限 24 小时，超出视为数据异常、整段失败。
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
                // 字段 5 只给基础 RRGGBB 颜色；大会员渐变来自字段 24，作为独立样式保留，
                // 不压进 RGB。
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
