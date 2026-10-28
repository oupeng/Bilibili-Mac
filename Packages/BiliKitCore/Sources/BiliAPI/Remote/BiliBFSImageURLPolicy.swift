import Foundation

/// B 站 BFS 图床图片的来源规则：评论头像、表情、正文图片、链接前置图标、热搜图标与关联视频弹幕的封面共用。
///
/// 只接受 `i0`／`i1`／`i2.hdslb.com` 与 `album.biliimg.com` 上 `/bfs/` 下的 HTTPS 路径，端口缺省或
/// 443，拒绝 userinfo、query、fragment、空段、点段、反斜杠、控制字符与编码后的 `%`、`/`、`\`；
/// 图片仍由无凭据的图片管线加载（见 SECURITY-MODEL §4）。`album.biliimg.com` 是同一图床的相册域名，
/// 较早的评论图片用它，缩略参数同样可用。
///
/// 调用方：`BiliCommentAssetResolver` 在拼缩略参数前后各检查一次，不通过时不加载该图或退回原图；
/// `TrendingSearchKeywordPayload` 在图标升级为 HTTPS 后检查，不通过时只丢图标；`DanmakuCommandDecoder` 对
/// 关联视频卡片的封面同样升级后检查，不通过时卡片只缺封面。
enum BiliBFSImageURLPolicy {
    private static let bfsPathPrefix = "/bfs/"
    /// 精确主机名，不做后缀匹配；新增主机即扩大无凭据图片请求可达的范围，须先确认是 B 站图床。
    private static let allowedHosts: Set<String> = [
        "i0.hdslb.com",
        "i1.hdslb.com",
        "i2.hdslb.com",
        "album.biliimg.com"
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
        // 编码后的 `%`、`/`、`\` 解码后可能拼出新的路径分隔或被二次解码，一律拒绝，
        // 见 SECURITY-MODEL §4。
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
