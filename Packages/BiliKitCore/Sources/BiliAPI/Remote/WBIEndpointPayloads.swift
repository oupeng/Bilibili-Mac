import Foundation

/// nav 的 `wbi_img`：两张图片地址，文件名（去扩展名）就是 WBI 的两段 key；地址本身不会被请求。
struct WBIImagePayload: Decodable, Sendable {
    let imageURL: String
    let subURL: String

    private enum CodingKeys: String, CodingKey {
        case imageURL = "img_url"
        case subURL = "sub_url"
    }
}

/// WBI nav（`/x/web-interface/nav`）的 `data`，只读取 `wbi_img`；由 `BiliAPIClient.wbiKey`
/// 匿名请求（见 SECURITY-MODEL §3）后构造 `WBIKeyMaterial`。
struct NavigationPayload: Decodable, Sendable {
    let wbiImage: WBIImagePayload

    private enum CodingKeys: String, CodingKey {
        case wbiImage = "wbi_img"
    }
}
