import BiliApplication
import BiliModels
import BiliNetworking
import CryptoKit
import Foundation

/// BilibiliSponsorBlock API 客户端与仓库实现
public final class BiliSponsorBlockRepository: SponsorBlockRepositoryPort, Sendable {
    private let httpClient: HTTPClient

    public init(httpClient: HTTPClient = HTTPClient()) {
        self.httpClient = httpClient
    }

    /// 计算字符串的 SHA-256 并截取前 4 位十六进制字符作为 Hash Prefix
    public static func computeHashPrefix(for bvid: String) -> String {
        let inputData = Data(bvid.utf8)
        let hashed = SHA256.hash(data: inputData)
        let hexString = hashed.map { String(format: "%02x", $0) }.joined()
        return String(hexString.prefix(4))
    }

    public func fetchSegments(bvid: String, serverURL: String) async throws -> [SponsorSegment] {
        guard !bvid.isEmpty else { return [] }

        let normalizedServerURL = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let hostURLString = normalizedServerURL.isEmpty ? SponsorBlockSettings.defaultServerURL : normalizedServerURL
        let hashPrefix = Self.computeHashPrefix(for: bvid)

        guard let url = URL(string: "\(hostURLString)/api/skipSegments/\(hashPrefix)") else {
            return []
        }

        let httpRequest = HTTPRequest(url: url, method: .get)

        let response: HTTPResponse
        do {
            response = try await httpClient.send(httpRequest)
        } catch {
            return []
        }

        guard response.statusCode == 200 else {
            return []
        }

        return parseSegments(from: response.body, matchingBvid: bvid)
    }

    private func parseSegments(from data: Data, matchingBvid bvid: String) -> [SponsorSegment] {
        struct RawSegmentResponse: Decodable {
            let videoID: String
            let hash: String?
            let segments: [RawSegmentItem]?
        }

        struct RawSegmentItem: Decodable {
            let category: String
            let actionType: String
            let segment: [Double]
            let UUID: String?
            let uuid: String?
        }

        let decoder = JSONDecoder()
        guard let rawResponses = try? decoder.decode([RawSegmentResponse].self, from: data) else {
            return []
        }

        guard let matchedGroup = rawResponses.first(where: { $0.videoID.caseInsensitiveCompare(bvid) == .orderedSame }) else {
            return []
        }

        guard let rawSegments = matchedGroup.segments else {
            return []
        }

        var result: [SponsorSegment] = []
        for raw in rawSegments {
            guard raw.segment.count >= 2 else { continue }
            let start = raw.segment[0]
            let end = raw.segment[1]
            guard end > start else { continue }

            let category = SponsorBlockCategory(rawValue: raw.category) ?? .sponsor
            let actionType = SponsorBlockActionType(rawValue: raw.actionType) ?? .skip
            let segmentID = raw.UUID ?? raw.uuid ?? UUID().uuidString

            result.append(SponsorSegment(
                id: segmentID,
                category: category,
                startSeconds: start,
                endSeconds: end,
                actionType: actionType
            ))
        }

        return result
    }
}
