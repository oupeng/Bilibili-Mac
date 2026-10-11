import Foundation

/// 把 query 的键或值中 RFC 3986 unreserved 以外的字符全部百分号编码。
///
/// `URLComponents.queryItems` 会保留 `+` 等字符，服务端按表单解码时 `+` 变成空格；用户输入的自由
/// 文本（搜索词）与 WBI 签名都必须按这一规则编码，两条路径对同一个词的编码保持一致。
enum URLQueryUnreservedEncoding {
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters)
    }
}
