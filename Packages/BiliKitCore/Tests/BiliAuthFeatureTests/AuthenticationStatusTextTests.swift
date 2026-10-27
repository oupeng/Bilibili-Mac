import BiliApplication
import Testing

@testable import BiliAuthFeature

/// 账号 sheet 进入落定的状态时通告它的标题，失败连同原因；进度态不通告。
struct AuthenticationStatusTextTests {
    @Test(arguments: [
        AuthenticationState.restoring, .requestingQRCode, .finalizing, .signingOut
    ])
    func progressStatesAreNotAnnounced(_ state: AuthenticationState) {
        #expect(AuthenticationStatusText.announcement(for: state) == nil)
    }

    @Test(arguments: [
        AuthenticationState.signedOut, .awaitingScan, .awaitingConfirmation, .signedIn(nil),
        .expired
    ])
    func settledStatesAnnounceTheirTitle(_ state: AuthenticationState) {
        #expect(
            AuthenticationStatusText.announcement(for: state)
                == AuthenticationStatusText.title(for: state)
        )
    }

    @Test
    func failureAnnouncementCarriesTheReason() throws {
        let announcement = try #require(
            AuthenticationStatusText.announcement(for: .failed(.network))
        )
        let reason = AuthenticationStatusText.detail(for: .network)
        #expect(announcement.contains(reason))
        #expect(announcement != reason)
    }
}
