/// 稿件 av 号换算为 BV 号；纯本地计算，不发请求。
///
/// B 站公开的对应规则：`(2⁵¹ | aid) ^ 异或常数` 按 58 进制写成 9 位，再交换两组位置。
enum BiliVideoAID {
    /// 规则覆盖的 av 号上界（不含），只换算 1 到 2⁵¹ − 1。
    private static let maximumAID: Int64 = 1 << 51
    private static let xorCode: Int64 = 23_442_827_791_579
    private static let alphabet = Array(
        "FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf"
    )
    private static let prefix = Array("BV1")
    private static let encodedLength = 9

    static func bvid(fromAID aid: Int64) -> String? {
        guard aid > 0, aid < maximumAID else { return nil }
        let base = Int64(alphabet.count)
        var value = (maximumAID | aid) ^ xorCode
        var characters = prefix + Array(repeating: Character("0"), count: encodedLength)
        for index in stride(from: characters.count - 1, through: prefix.count, by: -1) {
            characters[index] = alphabet[Int(value % base)]
            value /= base
        }
        characters.swapAt(3, 9)
        characters.swapAt(4, 7)
        return String(characters)
    }
}
