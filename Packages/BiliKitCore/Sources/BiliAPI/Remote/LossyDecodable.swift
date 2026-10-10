/// 单个元素解码失败时记为 nil，不让整个数组或外层对象一起失败。
struct LossyDecodable<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
