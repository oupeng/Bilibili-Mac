/// 数字或数字字符串形式的计数字段。
///
/// B 站计数字段有时是数字、有时是数字字符串；数据被隐藏时还会给 `"--"` 或 null。
/// 非数字一律为 nil，调用方必须显式处理“没有值”，不用哨兵值。
struct FlexibleInt64: Decodable, Sendable {
    let value: Int64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let number = try? container.decode(Int64.self) {
            value = number
        } else {
            value = Int64(try container.decode(String.self))
        }
    }
}
