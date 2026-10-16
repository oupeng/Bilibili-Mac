"""static 阶段检查脚本共用的 Swift 源文件读取：文件清单与注释/字符串遮蔽。

只做检查所需的最小词法：行注释、可嵌套的块注释、普通/多行/raw 字符串字面量与其中的插值。
遮蔽时用空格替换被遮蔽的字符并保留换行，因此偏移量与行号与原文一致。
"""

import subprocess

# 不属于产品或测试源码、不受检查的路径前缀。
EXCLUDED_PREFIXES = ("references/",)


def swift_files():
    """仓库里（含尚未暂存的新文件）所有受检查的 Swift 文件，按路径排序。"""
    listed = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.swift"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    return sorted(
        path for path in set(listed)
        if not path.startswith(EXCLUDED_PREFIXES) and _exists(path)
    )


def _exists(path):
    try:
        with open(path, "rb"):
            return True
    except OSError:
        return False


def read(path):
    """按 UTF-8 读取，去掉可能的 BOM。"""
    with open(path, encoding="utf-8-sig") as file:
        return file.read()


class _Scanner:
    def __init__(self, text, keep_strings):
        self.text = text
        self.out = list(text)
        self.keep_strings = keep_strings
        self.string_starts = []

    def blank(self, start, end):
        for index in range(start, min(end, len(self.text))):
            if self.out[index] != "\n":
                self.out[index] = " "

    def code(self, index, until_paren):
        """扫描代码直到文件结束，或（插值内）遇到匹配的右括号；返回结束位置。"""
        text, depth = self.text, 0
        while index < len(text):
            char = text[index]
            if text.startswith("//", index):
                end = text.find("\n", index)
                end = len(text) if end < 0 else end
                self.blank(index, end)
                index = end
            elif text.startswith("/*", index):
                index = self.block_comment(index)
            elif char == '"' or (char == "#" and self._raw_quote(index)):
                index = self.string(index)
            elif until_paren and char == "(":
                depth += 1
                index += 1
            elif until_paren and char == ")":
                if depth == 0:
                    return index + 1
                depth -= 1
                index += 1
            else:
                index += 1
        return index

    def _raw_quote(self, index):
        end = index
        while end < len(self.text) and self.text[end] == "#":
            end += 1
        return end < len(self.text) and self.text[end] == '"'

    def block_comment(self, start):
        text, depth, index = self.text, 0, start
        while index < len(text):
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
                if depth == 0:
                    break
            else:
                index += 1
        self.blank(start, index)
        return index

    def string(self, start):
        text, index = self.text, start
        hashes = 0
        while text[index] == "#":
            hashes += 1
            index += 1
        multiline = text.startswith('"""', index)
        quote = '"""' if multiline else '"'
        if not multiline and hashes == 0:
            self.string_starts.append(start)
        index += len(quote)
        closing = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        content_start = index
        while index < len(text):
            if text.startswith(escape, index):
                after = index + len(escape)
                if after < len(text) and text[after] == "(":
                    if not self.keep_strings:
                        self.blank(content_start, index)
                    index = self.code(after + 1, until_paren=True)
                    content_start = index
                    continue
                index = after + 1
            elif text.startswith(closing, index):
                if not self.keep_strings:
                    self.blank(content_start, index)
                return index + len(closing)
            elif text[index] == "\n" and not multiline:
                break
            else:
                index += 1
        if not self.keep_strings:
            self.blank(content_start, index)
        return index


def mask(text, keep_strings):
    """遮蔽注释（`keep_strings` 为 False 时也遮蔽字符串内容），返回 (遮蔽后文本, 单行普通字符串起点)。"""
    scanner = _Scanner(text, keep_strings)
    scanner.code(0, until_paren=False)
    return "".join(scanner.out), scanner.string_starts
