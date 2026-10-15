import BiliAPI
import BiliApplication
import BiliNetworking
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct BiliWatchHistoryRepositoryTests {
    @Test(
        "API failures retain their application-level category",
        arguments: [
            MappingCase(
                scenario: .authorizationRequired,
                expected: .authenticationRequired
            ),
            // 带凭据的请求收到 -101 才是凭据失效；Keychain 等本地凭据读不到单独归类，不当作失效。
            MappingCase(
                scenario: .apiRejected(code: -101),
                expected: .authenticationInvalid
            ),
            MappingCase(
                scenario: .credentialUnavailable,
                expected: .authenticationUnavailable
            ),
            MappingCase(
                scenario: .apiRejected(code: -412),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .apiRejected(code: -403),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .apiRejected(code: -352),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .httpStatus(403),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .httpStatus(412),
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .htmlRiskControlPage,
                expected: .requestRestricted
            ),
            MappingCase(
                scenario: .apiRejected(code: -500),
                expected: .serviceRejected(code: -500)
            ),
            MappingCase(
                scenario: .httpStatus(500),
                expected: .unavailable
            ),
            MappingCase(
                scenario: .invalidRequest,
                expected: .invalidRequest
            )
        ]
    )
    func mapsAPIFailure(testCase: MappingCase) async {
        let repository = testCase.scenario.repository()

        await #expect(throws: testCase.expected) {
            try await repository.watchHistory(
                after: nil,
                pageSize: testCase.scenario.pageSize
            )
        }
    }

    @Test
    func preservesCancellation() async {
        let repository = HistoryScenario.cancellation.repository()

        await #expect(throws: CancellationError.self) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }

    @Test
    func mapsUnknownTransportFailureToTransportFailure() async {
        let repository = HistoryScenario.unknownTransportFailure.repository()

        await #expect(throws: ContentApplicationError.transportFailure) {
            try await repository.watchHistory(after: nil, pageSize: 20)
        }
    }
}

struct MappingCase: Sendable, CustomTestStringConvertible {
    let scenario: HistoryScenario
    let expected: ContentApplicationError

    var testDescription: String {
        "\(scenario) -> \(expected)"
    }
}

enum HistoryScenario: Sendable, Equatable {
    case authorizationRequired
    case credentialUnavailable
    case apiRejected(code: Int)
    case httpStatus(Int)
    case htmlRiskControlPage
    case invalidRequest
    case cancellation
    case unknownTransportFailure

    var pageSize: Int {
        switch self {
        case .invalidRequest:
            0
        default:
            20
        }
    }

    func repository() -> BiliWatchHistoryRepository {
        // 空 reply 队列让 transport 抛出未知错误。
        let replies: [StubTransport.Reply] =
            switch self {
            case .apiRejected(let code):
                [.response(jsonResponse("{\"code\":\(code),\"message\":\"fixture\"}"))]
            case .httpStatus(let status):
                [.response(HTTPResponse(statusCode: status, body: Data()))]
            case .htmlRiskControlPage:
                [.response(htmlRiskControlResponse())]
            case .cancellation:
                [.cancellation]
            case .authorizationRequired, .credentialUnavailable, .invalidRequest,
                .unknownTransportFailure:
                []
            }
        let authorizer: StubAuthorizer? =
            switch self {
            case .authorizationRequired: nil
            case .credentialUnavailable: StubAuthorizer(.fail(.unavailable))
            default: StubAuthorizer()
            }
        return BiliWatchHistoryRepository(
            client: BiliAPIClient(
                transport: StubTransport(replies),
                requestAuthorizer: authorizer
            )
        )
    }
}
