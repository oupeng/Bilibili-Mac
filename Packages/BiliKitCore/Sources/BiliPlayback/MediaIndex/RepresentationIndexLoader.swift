import BiliModels
import BiliNetworking
import Foundation

public struct LoadedSegmentIndex: Sendable, Equatable {
    public let sourceURL: URL
    public let completeMediaLength: Int64?
    public let index: SegmentIndex

    public init(
        sourceURL: URL,
        completeMediaLength: Int64?,
        index: SegmentIndex
    ) {
        self.sourceURL = sourceURL
        self.completeMediaLength = completeMediaLength
        self.index = index
    }
}

/// 从候选 CDN 严格读取并解析 SIDX，同时保留实际成功的来源供媒体代理复用。
///
/// 超过 `SIDXParser.maximumBoxByteCount` 的 `index_range` 在发起任何请求前失败。
public struct RepresentationIndexLoader: Sendable {
    private let rangeClient: HTTPRangeClient
    private let parser: SIDXParser

    public init(
        rangeClient: HTTPRangeClient = HTTPRangeClient(),
        parser: SIDXParser = SIDXParser()
    ) {
        self.rangeClient = rangeClient
        self.parser = parser
    }

    public func load(
        for representation: MediaRepresentation,
        headers: [String: String] = [:]
    ) async throws -> LoadedSegmentIndex {
        let indexRange = representation.segmentBase.index
        let boxStartOffset = UInt64(indexRange.start)
        let range = try HTTPByteRange(
            start: indexRange.start,
            endInclusive: indexRange.endInclusive
        )
        guard range.length <= UInt64(SIDXParser.maximumBoxByteCount) else {
            throw SIDXParserError.indexTooLarge(byteCount: range.length)
        }
        let response = try await rangeClient.fetch(
            from: representation.urlCandidates,
            range: range,
            headers: headers,
            validateBody: { data in
                (try? parser.parse(
                    data,
                    boxStartOffset: boxStartOffset
                )) != nil
            }
        )
        let index = try parser.parse(
            response.body,
            boxStartOffset: boxStartOffset
        )

        return LoadedSegmentIndex(
            sourceURL: response.sourceURL,
            completeMediaLength: response.contentRange.completeLength,
            index: index
        )
    }
}
