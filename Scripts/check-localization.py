"""产品字符串目录必须完整提供四种语言，且译文保留源文的占位符。

在仓库根运行。由 run-quality-gates.sh 的 static 阶段调用；它只读源文件，不需要 App 进程。
"""

import json
import re
import sys

SUPPORTED_LANGUAGES = {"zh-Hans", "zh-Hant", "ja", "en"}
CATALOG_PATHS = [
    "BiliKitMac/Localizable.xcstrings",
    "Packages/BiliKitCore/Sources/BiliBrowseFeature/Resources/Localizable.xcstrings",
    "Packages/BiliKitCore/Sources/BiliAuthFeature/Resources/Localizable.xcstrings",
    "Packages/BiliKitCore/Sources/BiliLibraryFeature/Resources/Localizable.xcstrings",
]
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|llu|ld|lu|[df@])")
POSITION = re.compile(r"%\d+\$")


def placeholders(value):
    return sorted(POSITION.sub("%", match) for match in PLACEHOLDER.findall(value))


def catalog_failures(path):
    with open(path, encoding="utf-8") as file:
        catalog = json.load(file)
    if catalog.get("sourceLanguage") != "zh-Hans":
        yield f"{path}: sourceLanguage 必须是 zh-Hans"
    strings = catalog.get("strings") or {}
    if not strings:
        yield f"{path}: 没有任何字符串"
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


def main():
    failures = [failure for path in CATALOG_PATHS for failure in catalog_failures(path)]
    for failure in failures:
        print(f"本地化检查失败：{failure}", file=sys.stderr)
    if failures:
        return 1
    print("本地化字符串目录检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
