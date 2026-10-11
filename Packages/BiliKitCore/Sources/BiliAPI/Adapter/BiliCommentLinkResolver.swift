import BiliModels
import BiliNetworking
import Foundation

public struct BiliCommentLinkResolver: Sendable {
    private let publicHTTPSPolicy = PublicHTTPSURLPolicy()

    public init() {}

    public func externalURL(for target: CommentLinkTarget) -> URL? {
        switch target {
        case .video:
            return nil
        case .member(let user):
            guard let memberID = user.id.memberID else { return nil }
            return Self.spaceURL(memberID)
        case .space(let memberID):
            guard memberID > 0 else { return nil }
            return Self.spaceURL(memberID)
        case .external(let reference):
            guard let url = reference.remoteURL,
                allowsUserInitiatedExternalURL(url)
            else { return nil }
            return url
        }
    }

    /// 空间不可用（没有空间功能）时的网页回退。
    private static func spaceURL(_ memberID: Int64) -> URL? {
        URL(string: "https://space.bilibili.com/\(memberID)")
    }

    private func allowsUserInitiatedExternalURL(_ url: URL) -> Bool {
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else { return false }
        components.fragment = nil
        guard let validationURL = components.url else { return false }
        return publicHTTPSPolicy.allows(validationURL)
    }
}
