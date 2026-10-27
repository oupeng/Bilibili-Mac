import BiliModels
import BiliUI
import Foundation

/// 评论区的计数缩写与页数计算；计数缩写沿用 BiliUI 的视频元数据格式。
public enum CommentPresentationFormatting {
    public static func compactCount(
        _ count: Int64,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        VideoMetadataFormatting.compactCount(count, locale: locale)
    }

    public static func compactCount(
        _ count: Int,
        locale: Locale = InterfaceLocale.current
    ) -> String {
        VideoMetadataFormatting.compactCount(Int64(clamping: count), locale: locale)
    }

    public static func pageCount(totalCount: Int, pageSize: Int) -> Int {
        PageNumbering.pageCount(totalCount: totalCount, pageSize: pageSize)
    }
}
