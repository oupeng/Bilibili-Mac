import BiliApplication
import BiliModels
import Testing

@Suite(.timeLimit(.minutes(1)))
struct UploaderProfileUseCaseTests {
    @Test(
        arguments: [
            ("  记录生活\n也记录技术  ", "记录生活 也记录技术"),
            (nil, nil),
            ("", nil),
            (" \t\n ", nil)
        ] as [(String?, String?)]
    )
    func collapsesWhitespaceAndTreatsBlankSignatureAsAbsent(
        remote: String?,
        expected: String?
    ) async throws {
        let useCase = UploaderProfileUseCase(
            repository: UploaderProfileRepositoryStub(
                result: UploaderProfile(signature: remote)
            )
        )

        #expect(try await useCase.profile(for: 10_001).signature == expected)
    }

    @Test(arguments: [true, false])
    func keepsVIPStateWhileNormalizingSignature(isVIP: Bool) async throws {
        let useCase = UploaderProfileUseCase(
            repository: UploaderProfileRepositoryStub(
                result: UploaderProfile(signature: " ", isVIP: isVIP)
            )
        )

        #expect(
            try await useCase.profile(for: 10_001)
                == UploaderProfile(signature: nil, isVIP: isVIP)
        )
    }

    @Test
    func rejectsInvalidOwnerBeforeRepository() async {
        let repository = UploaderProfileRepositoryStub(result: UploaderProfile())
        let useCase = UploaderProfileUseCase(repository: repository)

        await #expect(throws: ContentApplicationError.invalidRequest) {
            try await useCase.profile(for: 0)
        }
        #expect(await repository.callCount == 0)
    }
}

private actor UploaderProfileRepositoryStub: UploaderProfileRepository {
    private let result: UploaderProfile
    private(set) var callCount = 0

    init(result: UploaderProfile) {
        self.result = result
    }

    func uploaderProfile(for ownerID: Int64) async throws -> UploaderProfile {
        callCount += 1
        return result
    }
}
