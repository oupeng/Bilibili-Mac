/// 接口里 `"MM:SS"` 或 `"H:MM:SS"` 形式的时长文本（搜索结果、UP 主空间投稿）。
enum RemoteClockDuration {
    /// 只接受 2 或 3 段非负整数；空段（如 `"1::30"`）、负数或其他形状都返回 nil。
    static func seconds(_ value: String) -> Int? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(components.count) else { return nil }
        var seconds = 0
        for component in components {
            guard let number = Int(component), number >= 0 else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }
}
