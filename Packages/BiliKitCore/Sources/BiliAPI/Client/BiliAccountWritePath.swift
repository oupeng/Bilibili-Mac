/// 用户发起的账户写入的 endpoint path；`BiliAPIClient` 的写 endpoint 用它构造请求，App Composition 用它声明窗口主 API 的
/// 写 allowlist（`LiveAPIClients.mainAccountWriteAllowedPaths`）。
///
/// 与 `BiliAccountReadPath` 同理：endpoint 与 allowlist 引用同一个常量。BiliAuth 的 `BiliAccountWriteRequestAuthorizer`
/// 另有一张按 path 的封闭 schema 表（BiliAuth 不能依赖 BiliAPI，字面量各写一份），Composition 的测试核对 allowlist 里的
/// 每个 path 都能被它授权。观看进度 heartbeat 不在这里，它有自己的授权器。见 SECURITY-MODEL §3。
public enum BiliAccountWritePath {
    /// 加入稍后再看（`aid`、`csrf`，urlencoded）。
    public static let watchLaterAdd = "/x/v2/history/toview/add"
    /// 从稍后再看移除单条（`aid`、`csrf`，urlencoded，不签 WBI）。
    ///
    /// 网页稍后再看页实际用 `/x/v2/history/toview/v2/dels`（WBI 签名、multipart，字段 `resources`）；单条接口有文档、多个
    /// 第三方客户端在用，表单最简单，所以先用它。实机失效时改用 `v2/dels`，并同步授权器的 schema。
    public static let watchLaterRemove = "/x/v2/history/toview/del"
}
