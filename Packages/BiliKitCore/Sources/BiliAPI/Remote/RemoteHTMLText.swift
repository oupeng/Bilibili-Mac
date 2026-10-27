import Foundation

/// 把远端接口里按 HTML 转义过的文字一次性规范为语义纯文本。
///
/// 列表视频标题、推荐理由与评论正文都以转义形式下发（如 `&gt;`、`&#x27;`）；映射为模型时在这里解码一次，
/// 界面拿到的始终是纯文本，不再解码，也不再按 HTML 解释。
enum RemoteHTMLText {
    /// 只解码 HTML 实体；列表标题、推荐理由与评论正文用它。
    static func plainText(_ value: String) -> String {
        decodingHTMLEntities(in: value)
    }

    /// 搜索结果标题带高亮 HTML 标签：先去掉所有标签再解码实体。
    static func searchResult(_ value: String) -> String {
        decodingHTMLEntities(in: strippingTags(from: value))
    }

    /// 只认 `amp`、`apos`、`gt`、`lt`、`nbsp`、`quot` 与数字实体；
    /// `&` 后 32 个字符内没有分号或实体不认识时原样保留，解出控制字符的数字实体也不解码。
    private static func decodingHTMLEntities(in value: String) -> String {
        guard value.contains("&") else { return value }

        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&" else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }

            let entityStart = value.index(after: index)
            let maximumEnd =
                value.index(
                    entityStart,
                    offsetBy: 32,
                    limitedBy: value.endIndex
                ) ?? value.endIndex
            guard
                let semicolon = value[entityStart..<maximumEnd]
                    .firstIndex(of: ";"),
                let decoded = decodedEntity(value[entityStart..<semicolon])
            else {
                result.append("&")
                index = entityStart
                continue
            }

            result.append(decoded)
            index = value.index(after: semicolon)
        }
        return result
    }

    private static func decodedEntity(_ entity: Substring) -> String? {
        switch entity {
        case "amp":
            return "&"
        case "apos":
            return "'"
        case "gt":
            return ">"
        case "lt":
            return "<"
        case "nbsp":
            return "\u{00A0}"
        case "quot":
            return "\""
        default:
            return decodedNumericEntity(entity)
        }
    }

    private static func decodedNumericEntity(_ entity: Substring) -> String? {
        guard entity.first == "#" else { return nil }
        let numeric = entity.dropFirst()
        let radix: Int
        let digits: Substring
        if numeric.first == "x" || numeric.first == "X" {
            radix = 16
            digits = numeric.dropFirst()
        } else {
            radix = 10
            digits = numeric
        }
        guard
            !digits.isEmpty,
            let value = UInt32(digits, radix: radix),
            let scalar = UnicodeScalar(value),
            scalar.properties.generalCategory != .control
        else {
            return nil
        }
        return String(scalar)
    }

    private static func strippingTags(from value: String) -> String {
        var result = ""
        var isInsideTag = false
        for character in value {
            switch character {
            case "<":
                isInsideTag = true
            case ">":
                isInsideTag = false
            default:
                if !isInsideTag {
                    result.append(character)
                }
            }
        }
        return result
    }
}
