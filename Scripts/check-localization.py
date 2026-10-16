"""产品字符串目录必须完整提供四种语言，译文保留源文的占位符，并与代码里的 key 一一对应。

在仓库根运行。由 run-quality-gates.sh 的 static 阶段调用；它只读源文件，不需要 App 进程。

字符串目录按位置自动发现：App 是 `BiliKitMac/Localizable.xcstrings`，Package target 是
`<target>/Resources/Localizable.xcstrings`。每个范围里 `XxxStrings.localized("…")` 的字面量
（App 另加 SwiftUI 以非 ASCII 字面量构造的 `Text("…")` 等）都必须是本范围目录里的 key；目录里的
key 也必须仍出现在本范围的某个字符串字面量里。缺 key 时运行期会静默回退到中文源文，残留 key
会让译文与代码脱节。key 必须在调用点写成单行字面量，不支持动态拼出的 key；注释里的代码不计。
Package target 里未指定 bundle 的 SwiftUI 字面量查的是 App 的 `Bundle.main`，所以非 ASCII
字面量必须改用本 target 的 `XxxStrings.localized`。
"""

import glob
import json
import os
import re
import sys

import swift_source

SUPPORTED_LANGUAGES = {"zh-Hans", "zh-Hant", "ja", "en"}
APP_SOURCES = "BiliKitMac"
APP_CATALOG = "BiliKitMac/Localizable.xcstrings"
PACKAGE_SOURCES = "Packages/BiliKitCore/Sources"
# 插值在 key 里对应的占位符：具体是 %@、%lld 还是 %lf 由插值类型决定，静态只能匹配其一。
PLACEHOLDER_PATTERN = r"%(?:\d+\$)?(?:lld|llu|ld|lu|lf|[df@])"
PLACEHOLDER = re.compile(PLACEHOLDER_PATTERN)
POSITION = re.compile(r"%\d+\$")
INTERPOLATION_KEY = PLACEHOLDER_PATTERN

HELPER_CALL = re.compile(r"\b[A-Z]\w*Strings\.localized\(\s*\"")
# 以字符串字面量为首个参数、按 LocalizedStringKey 查表的 SwiftUI 构造与修饰符。
SWIFTUI_LITERAL = re.compile(
    r"(?:\b(?:Text|Button|Label|Toggle|Section|Picker|Menu|LabeledContent|TextField|SecureField|Link|Tab"
    r"|ProgressView|Stepper|DisclosureGroup|NavigationLink|CommandMenu|ContentUnavailableView"
    r"|WindowGroup|Window)"
    r"|\.(?:help|navigationTitle|navigationSubtitle|accessibilityLabel|accessibilityHint|accessibilityValue"
    r"|badge|alert|confirmationDialog))"
    r"\(\s*\""
)
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


def placeholders(value):
    return sorted(POSITION.sub("%", match) for match in PLACEHOLDER.findall(value))


def catalog_failures(path, strings):
    for key, entry in strings.items():
        localizations = entry.get("localizations") or {}
        if set(localizations) != SUPPORTED_LANGUAGES:
            yield f"{path}: {key} 必须恰好提供四种语言"
        for language in sorted(SUPPORTED_LANGUAGES):
            unit = (localizations.get(language) or {}).get("stringUnit")
            if unit is None:
                yield f"{path}: {key} 缺少 {language}"
                continue
            value = unit.get("value", "")
            if unit.get("state") != "translated":
                yield f"{path}: {key} 的 {language} 未标记为 translated"
            if not value.strip():
                yield f"{path}: {key} 的 {language} 译文为空"
            if placeholders(value) != placeholders(key):
                yield f"{path}: {key} 的 {language} 改变了占位符"


def parse_literal(text, start):
    """从 `start` 处的开引号解析单行字符串字面量，返回 (key 正则, 是否含非 ASCII, 结束位置)。"""
    parts, plain, index = [], [], start + 1
    while index < len(text):
        char = text[index]
        if char == '"':
            break
        if char == "\n":
            return None, False, index
        if char == "\\":
            following = text[index + 1] if index + 1 < len(text) else ""
            if following == "(":
                depth, index = 1, index + 2
                while index < len(text) and depth:
                    if text[index] == "(":
                        depth += 1
                    elif text[index] == ")":
                        depth -= 1
                    index += 1
                parts.append(None)
                continue
            if following == "u" and text[index + 2:index + 3] == "{":
                end = text.index("}", index)
                literal = chr(int(text[index + 3:end], 16))
                index = end + 1
            else:
                literal = ESCAPES.get(following, following)
                index += 2
        else:
            literal = char
            index += 1
        plain.append(literal)
        parts.append(literal)
    # 含插值的字面量经 appendLiteral 生成 key，其中的 % 写成 %%；不含插值时 key 就是字面量本身。
    interpolated = None in parts
    pattern = "".join(
        INTERPOLATION_KEY if part is None
        else re.escape(part.replace("%", "%%") if interpolated else part)
        for part in parts
    )
    has_non_ascii = any(ord(char) > 127 for char in plain)
    return pattern, has_non_ascii, index


class SourceFile:
    """注释已遮蔽的源文件；偏移量与行号与原文一致。"""

    def __init__(self, path):
        self.path = path
        self.text, self.string_starts = swift_source.mask(swift_source.read(path), keep_strings=True)

    def line(self, offset):
        return self.text.count("\n", 0, offset) + 1

    def calls(self, call_pattern):
        """产出 (行号, key 正则或 None, 是否含非 ASCII, 是否显式指定 bundle)；None 表示不是单行字面量。"""
        for match in call_pattern.finditer(self.text):
            start = match.end() - 1
            line_end = self.text.find("\n", start)
            rest = self.text[start:line_end if line_end >= 0 else len(self.text)]
            if self.text.startswith('"""', start):
                yield self.line(match.start()), None, False, False
                continue
            pattern, has_non_ascii, _ = parse_literal(self.text, start)
            yield self.line(match.start()), pattern, has_non_ascii, "bundle:" in rest

    def literal_patterns(self):
        """文件里每个单行普通字符串字面量对应的 key 正则（用于判断目录里的 key 是否仍被使用）。"""
        for start in self.string_starts:
            pattern, _, _ = parse_literal(self.text, start)
            if pattern:
                yield pattern


def scopes():
    """返回 (源码根, 字符串目录或 None, 是否按 Bundle.main 查 SwiftUI 字面量)。"""
    yield APP_SOURCES, APP_CATALOG, True
    for target in sorted(os.listdir(PACKAGE_SOURCES)):
        root = os.path.join(PACKAGE_SOURCES, target)
        if os.path.isdir(root):
            catalog = os.path.join(root, "Resources", "Localizable.xcstrings")
            yield root, catalog if os.path.isfile(catalog) else None, False


def usage_failures(root, catalog_path, keys, swiftui_uses_catalog):
    """调用点的字面量必须在目录里；目录里的 key 必须仍出现在本范围的某个字符串字面量里。

    调用点只识别 `HELPER_CALL` 与 `SWIFTUI_LITERAL` 的首个参数；key 是否仍被使用则看本范围
    全部单行字符串字面量，三元表达式、ASCII 文案或清单外的构造器里的 key 不会被误判为残留。
    """
    matchers = {}
    used = set()
    paths = [path for path in swift_source.swift_files() if path.startswith(root + "/")]
    for path in paths:
        source = SourceFile(path)
        uses = []
        for line, pattern, _, _ in source.calls(HELPER_CALL):
            uses.append((line, pattern))
        for line, pattern, has_non_ascii, explicit_bundle in source.calls(SWIFTUI_LITERAL):
            if not has_non_ascii or explicit_bundle:
                continue
            if swiftui_uses_catalog:
                uses.append((line, pattern))
            else:
                yield f"{path}:{line}: Package 里未指定 bundle 的 SwiftUI 字面量会查 App 的 Bundle.main，改用本 target 的 XxxStrings.localized"
        for line, pattern in uses:
            if pattern is None:
                yield f"{path}:{line}: 本地化 key 必须写成单行字符串字面量"
            elif catalog_path is None:
                yield f"{path}:{line}: 所在 target 没有 Resources/Localizable.xcstrings"
            elif not any(re.fullmatch(pattern, key) for key in keys):
                yield f"{path}:{line}: {catalog_path} 里没有对应的 key"
        for pattern in source.literal_patterns():
            matcher = matchers.setdefault(pattern, re.compile(pattern))
            used |= {key for key in keys if key not in used and matcher.fullmatch(key)}
    for key in sorted(set(keys) - used):
        yield f"{catalog_path}: {key} 已没有代码使用，删除这一项"


def main():
    failures = []
    for root, catalog_path, swiftui_uses_catalog in scopes():
        keys = {}
        if catalog_path is not None:
            with open(catalog_path, encoding="utf-8") as file:
                catalog = json.load(file)
            if catalog.get("sourceLanguage") != "zh-Hans":
                failures.append(f"{catalog_path}: sourceLanguage 必须是 zh-Hans")
            keys = catalog.get("strings") or {}
            if not keys:
                failures.append(f"{catalog_path}: 没有任何字符串")
            failures.extend(catalog_failures(catalog_path, keys))
        failures.extend(usage_failures(root, catalog_path, keys, swiftui_uses_catalog))
    stray = set(glob.glob("**/Localizable.xcstrings", recursive=True)) - {
        catalog for _, catalog, _ in scopes() if catalog is not None
    }
    for path in sorted(stray):
        if not path.startswith(swift_source.EXCLUDED_PREFIXES):
            failures.append(f"{path}: 字符串目录不在 App 根或 target 的 Resources/ 下，不会被检查")
    for failure in failures:
        print(f"本地化检查失败：{failure}", file=sys.stderr)
    if failures:
        return 1
    print("本地化字符串目录检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
