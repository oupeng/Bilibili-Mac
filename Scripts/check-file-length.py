"""Swift 文件不超过 800 行；已经超过的文件只能变短，不能再变长。

在仓库根运行，由 run-quality-gates.sh 的 static 阶段调用。`OVERSIZED` 记录每个超长文件当前
允许的最大行数：文件变长、新增超长文件都失败；文件缩短后要同步下调或删除它的条目，
条目过期（文件已删除、已不超过 800 行或比记录短）同样失败，避免上限悄悄留出余量。
文件清单与架构检查相同（swift_source.swift_files）；生成的 protobuf 文件不计入。
"""

import sys

import swift_source

LIMIT = 800
GENERATED_SUFFIX = ".pb.swift"

OVERSIZED = {
    "BiliKitMacTests/VideoDetailLifecycleTests.swift": 1185,
    "Packages/BiliKitCore/Tests/BiliAPITests/BiliAPIClientTests.swift": 2166,
    "Packages/BiliKitCore/Tests/BiliAPITests/CommentAPIClientTests.swift": 946,
    "Packages/BiliKitCore/Tests/BiliDanmakuTests/DanmakuPresentationControllerTests.swift": 1023,
    "Packages/BiliKitCore/Tests/BiliDanmakuTests/DanmakuSessionTests.swift": 802,
    "Packages/BiliKitCore/Tests/BiliPlaybackTests/AVPlayerEngineLifecycleTests.swift": 835,
}


def line_counts():
    for path in swift_source.swift_files():
        if not path.endswith(GENERATED_SUFFIX):
            with open(path, encoding="utf-8") as file:
                yield path, sum(1 for _ in file)


def failures():
    counts = dict(line_counts())
    for path, lines in sorted(counts.items()):
        ceiling = OVERSIZED.get(path, LIMIT)
        if lines > ceiling:
            if path in OVERSIZED:
                yield f"{path}: {lines} 行，超过记录的 {ceiling} 行；超长文件只能缩短，新增代码按职责拆到新文件"
            else:
                yield f"{path}: {lines} 行，超过 {LIMIT} 行；按职责拆分"
    for path, ceiling in sorted(OVERSIZED.items()):
        lines = counts.get(path)
        if lines is None:
            yield f"{path}: 文件已不存在，删除 OVERSIZED 里的条目"
        elif lines <= LIMIT:
            yield f"{path}: 已缩到 {lines} 行，删除 OVERSIZED 里的条目"
        elif lines < ceiling:
            yield f"{path}: 已缩到 {lines} 行，把 OVERSIZED 里的上限从 {ceiling} 下调到 {lines}"


def main():
    found = list(failures())
    for failure in found:
        print(f"文件长度检查失败：{failure}", file=sys.stderr)
    if found:
        return 1
    print("文件长度检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
