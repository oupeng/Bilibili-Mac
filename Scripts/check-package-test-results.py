"""核对包测试确实跑完：应运行的每个测试都在 xUnit 结果里，且没有失败。

由 isolated-toolchain.sh 的 package_test 在 `swift test` 之后调用。测试进程中途正常退出时
（测试或被测代码调用 `exit(0)`，或 AppKit 让 Swift 并发主执行器的 `CFRunLoopRun` 返回，
运行时随即 `exit(0)`），swift test 的退出码仍是 0；SwiftPM 按测试 bundle 分进程运行，
终端里的“passed”汇总行也可能来自别的 bundle。两者都不能证明测试跑完，所以逐个比对：

- 应运行集合：`swift test list` 的输出（每行一个 `模块.Suite/测试()`，嵌套 suite 用 `/` 分隔），
  按筛选器选取。筛选器与 `swift test --filter` 相同，测试或它所在的任一层 suite／模块与正则
  部分匹配即被选中。
- 已运行集合：xUnit 结果里的 testcase，`classname.name` 与列表 ID 把 `/` 换成 `.` 后一一对应；
  参数化测试的多个用例在两边都只算一条。

缺少的、多出的、带 failure／error 的，或筛选器一个测试也没选中，都失败。

用法：check-package-test-results.py <list 输出> <xunit 路径> [筛选器]
xunit 路径即传给 `swift test --xunit-output` 的路径：SwiftPM 把 XCTest 结果写在这里，
Swift Testing 结果写在同名加 `-swift-testing` 后缀的文件里；不存在的文件按没有结果处理。
"""

import re
import sys
import xml.etree.ElementTree as ElementTree
from pathlib import Path

# 失败时最多列出的测试 ID 条数；只影响输出长度，不影响判定。
REPORT_LIMIT = 20


def scopes(test_id):
    """测试自身与它所在的每一层：模块、模块.Suite、模块.Suite/内层 Suite……"""
    module, _, path = test_id.partition(".")
    yield module
    components = path.split("/")
    for end in range(1, len(components) + 1):
        yield f"{module}.{'/'.join(components[:end])}"


def expected_ids(listing, test_filter):
    """按筛选器选出的应运行测试，ID 已换成与 xUnit 相同的 `.` 分隔形式。"""
    test_ids = {line.strip() for line in listing.splitlines() if line.strip()}
    if test_filter:
        pattern = re.compile(test_filter)
        test_ids = {test_id for test_id in test_ids if any(pattern.search(s) for s in scopes(test_id))}
    return {test_id.replace("/", ".") for test_id in test_ids}


def result_paths(xunit_path):
    path = Path(xunit_path)
    return [path, path.with_name(f"{path.stem}-swift-testing{path.suffix}")]


def recorded_results(paths):
    """返回（已运行的测试 ID 集合，失败的测试 ID 列表）。"""
    ran, failed = set(), []
    for path in paths:
        if not path.exists():
            continue
        for case in ElementTree.parse(path).getroot().iter("testcase"):
            test_id = f"{case.get('classname')}.{case.get('name')}"
            ran.add(test_id)
            if case.find("failure") is not None or case.find("error") is not None:
                failed.append(test_id)
    return ran, failed


def problems(expected, paths, test_filter):
    if not expected:
        return [f"筛选器没有选中任何测试：{test_filter!r}"]
    try:
        ran, failed = recorded_results(paths)
    except ElementTree.ParseError as error:
        return [f"xUnit 结果无法解析（测试进程可能中途退出）：{error}"]

    found = []
    for title, ids in (
        ("没有结果（测试进程可能中途退出）", expected - ran),
        ("不在应运行列表里", ran - expected),
        ("失败", set(failed)),
    ):
        if ids:
            shown = sorted(ids)[:REPORT_LIMIT]
            more = f"\n  ……另有 {len(ids) - len(shown)} 个" if len(ids) > len(shown) else ""
            found.append(f"{len(ids)} 个测试{title}：\n  " + "\n  ".join(shown) + more)
    return found


def main(argv):
    if len(argv) not in (3, 4):
        print("用法：check-package-test-results.py <list 输出> <xunit 路径> [筛选器]", file=sys.stderr)
        return 2
    listing = Path(argv[1]).read_text(encoding="utf-8")
    test_filter = argv[3] if len(argv) == 4 else ""
    expected = expected_ids(listing, test_filter)
    found = problems(expected, result_paths(argv[2]), test_filter)
    if found:
        print("[Gate] 包测试没有完整通过：", file=sys.stderr)
        for problem in found:
            print(problem, file=sys.stderr)
        return 1
    print(f"[Gate] 包测试结果完整：{len(expected)} 个测试都有结果且通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
