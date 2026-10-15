import BiliAPI
import BiliModels
import BiliNetworking
import Testing

struct SponsorBlockAPITests {
    @Test func decodesSponsorSegmentPayloads() throws {
        let json = """
        [
            {
                "UUID": "uuid-1234",
                "cid": "123456",
                "category": "sponsor",
                "actionType": "skip",
                "segment": [10.5, 30.0],
                "votes": 5,
                "locked": 1
            }
        ]
        """
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let payloads = try decoder.decode([SponsorSegmentPayload].self, from: data)
        #expect(payloads.count == 1)

        let segment = try #require(payloads[0].model())
        #expect(segment.uuid == "uuid-1234")
        #expect(segment.cid == "123456")
        #expect(segment.category == "sponsor")
        #expect(segment.actionType == "skip")
        #expect(segment.startTimeSeconds == 10.5)
        #expect(segment.endTimeSeconds == 30.0)
        #expect(segment.votes == 5)
        #expect(segment.locked == 1)
    }
}
