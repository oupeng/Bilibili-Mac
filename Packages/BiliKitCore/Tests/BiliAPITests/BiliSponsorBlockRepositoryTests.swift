import BiliAPI
import BiliModels
import BiliNetworking
import Testing

struct BiliSponsorBlockRepositoryTests {
    @Test
    func hashPrefixComputationMatchesExpectedSHA256Prefix() {
        // BV1xx411c7m9
        let bvid = "BV1xx411c7m9"
        let prefix = BiliSponsorBlockRepository.computeHashPrefix(for: bvid)
        #expect(prefix.count == 4)
    }

    @Test
    func parseSegmentsSuccessfullyExtractsMatchingBvidSegments() async throws {
        let jsonResponse = """
        [
            {
                "videoID": "BV1xx411c7m9",
                "hash": "12345678",
                "segments": [
                    {
                        "category": "sponsor",
                        "actionType": "skip",
                        "segment": [10.5, 30.0],
                        "UUID": "test-uuid-1"
                    },
                    {
                        "category": "intro",
                        "actionType": "skip",
                        "segment": [0.0, 5.0],
                        "UUID": "test-uuid-2"
                    }
                ]
            }
        ]
        """

        let stubTransport = StubTransport { _ in
            HTTPResponse(
                statusCode: 200,
                headers: [:],
                data: Data(jsonResponse.utf8)
            )
        }

        let httpClient = HTTPClient(transport: stubTransport)
        let repository = BiliSponsorBlockRepository(httpClient: httpClient)

        let segments = try await repository.fetchSegments(bvid: "BV1xx411c7m9", serverURL: "https://bsb.hanydd.com")
        #expect(segments.count == 2)

        #expect(segments[0].id == "test-uuid-1")
        #expect(segments[0].category == .sponsor)
        #expect(segments[0].startSeconds == 10.5)
        #expect(segments[0].endSeconds == 30.0)

        #expect(segments[1].id == "test-uuid-2")
        #expect(segments[1].category == .intro)
        #expect(segments[1].startSeconds == 0.0)
        #expect(segments[1].endSeconds == 5.0)
    }
}
