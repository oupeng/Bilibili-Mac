import BiliModels
import Foundation

public struct BiliCommentAssetResolver: Sendable {
    public init() {}

    public func imageURL(for reference: CommentAssetReference) -> URL? {
        guard let url = reference.remoteURL, BiliBFSImageURLPolicy.allows(url) else {
            return nil
        }
        return url
    }
}
