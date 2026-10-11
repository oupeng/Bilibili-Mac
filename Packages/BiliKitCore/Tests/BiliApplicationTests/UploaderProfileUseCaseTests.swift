import BiliApplication
import BiliModels
import Foundation
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

    /// 名字与签名同一规则：折叠空白，空白名字视为缺省；头像原样保留。
    @Test(
        arguments: [
            ("  名字\n两行 ", "名字 两行"),
            (nil, nil),
            (" ", nil)
        ] as [(String?, String?)]
    )
    func normalizesNameAndKeepsAvatar(remote: String?, expected: String?) async throws {
        let avatarURL = try #require(URL(string: "https://i0.hdslb.com/bfs/face/fixture.jpg"))
        let useCase = UploaderProfileUseCase(
            repository: UploaderProfileRepositoryStub(
                result: UploaderProfile(name: remote, avatarURL: avatarURL)
            )
        )

        let profile = try await useCase.profile(for: 10_001)

        #expect(profile.name == expected)
        #expect(profile.avatarURL == avatarURL)
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
