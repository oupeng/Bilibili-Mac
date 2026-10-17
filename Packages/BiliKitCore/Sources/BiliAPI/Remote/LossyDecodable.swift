/// 单个元素解码失败时记为 nil，不让整个数组或外层对象一起失败。
struct LossyDecodable<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// 单个字段解码失败时按缺失处理，不让外层对象一起失败。
///
/// `decodeLossyBool` 另把 0／1 整数当作布尔值，其他取值按缺失处理。
extension KeyedDecodingContainer {
    func decodeLossyIfPresent<Value: Decodable>(
        _ type: Value.Type,
        forKey key: Key
    ) -> Value? {
        try? decodeIfPresent(type, forKey: key)
    }

    func decodeLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            switch value {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return nil
    }
}
