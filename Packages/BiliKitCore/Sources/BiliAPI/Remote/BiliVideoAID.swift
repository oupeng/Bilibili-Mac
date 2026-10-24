/// 稿件 av 号与 BV 号的互相换算；纯本地计算，不发请求。
///
/// B 站公开的对应规则：`(2⁵¹ | aid) ^ 异或常数` 按 58 进制写成 9 位，再交换两组位置。评论链接把 av 号换成 BV 号，
/// 账户写入（稍后再看等）把卡片的 BV 号换回 av 号：写接口一律传 aid，不为换算另发请求。
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

    /// `bvid(fromAID:)` 的逆运算；不是这套规则编码出的 BV 号（长度、前缀、字符或范围不符）时为 nil。
    ///
    /// 解出的 av 号再编码一次必须得到同一个 BV 号，所以大小写不同、多出位数的输入都不会被换算成某个 aid。
    static func aid(fromBVID bvid: String) -> Int64? {
        var characters = Array(bvid)
        guard characters.count == prefix.count + encodedLength,
            Array(characters.prefix(prefix.count)) == prefix
        else { return nil }
        characters.swapAt(3, 9)
        characters.swapAt(4, 7)
        let base = Int64(alphabet.count)
        var value: Int64 = 0
        for character in characters.dropFirst(prefix.count) {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: base)
            guard !overflow else { return nil }
            value = multiplied + Int64(digit)
        }
        let unmasked = value ^ xorCode
        guard unmasked & maximumAID != 0 else { return nil }
        let aid = unmasked & (maximumAID - 1)
        guard Self.bvid(fromAID: aid) == bvid else { return nil }
        return aid
    }
}
