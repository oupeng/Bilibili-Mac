import Foundation

/// B 站 BFS 图床图片的来源规则：评论头像、表情、正文图片与热搜图标共用。
///
/// 只接受 `i0`／`i1`／`i2.hdslb.com` 上 `/bfs/` 下的 HTTPS 路径，拒绝 query、fragment、点段与
/// 编码分隔符；图片仍由无凭据的图片管线加载。
enum BiliBFSImageURLPolicy {
    private static let bfsPathPrefix = "/bfs/"
    private static let allowedHosts: Set<String> = [
        "i0.hdslb.com",
        "i1.hdslb.com",
        "i2.hdslb.com"
    ]

    static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased(),
            allowedHosts.contains(host),
            url.port == nil || url.port == 443,
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil
        else { return false }
        return isSafeBFSPath(url)
    }

    private static func isSafeBFSPath(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        let encodedPath = components.percentEncodedPath
        let lowercaseEncodedPath = encodedPath.lowercased()
        guard encodedPath.hasPrefix(bfsPathPrefix),
            encodedPath.count > bfsPathPrefix.count,
            !lowercaseEncodedPath.contains("%25"),
            !lowercaseEncodedPath.contains("%2f"),
            !lowercaseEncodedPath.contains("%5c")
        else { return false }

        let decodedPath = url.path
        guard !decodedPath.contains("\\"),
            !decodedPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return false }
        let resourceComponents =
            decodedPath
            .dropFirst(bfsPathPrefix.count)
            .split(separator: "/", omittingEmptySubsequences: false)
        return !resourceComponents.isEmpty
            && resourceComponents.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
