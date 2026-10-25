"""包测试结果核对：每个应运行的测试都要有通过的结果，缺少、多出、失败或筛选为空都判失败。"""
import importlib.util
import sys

sys.dont_write_bytecode = True
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "check_package_test_results",
    Path(__file__).resolve().parent.parent / "check-package-test-results.py",
)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)

LISTING = """\
ModA.FeedTests/first()
ModA.FeedTests/second(_:)
ModB.Outer/InnerTests/third()
"""


def xunit(*cases, failing=()):
    rows = []
    for case in cases:
        classname, _, name = case.rpartition(".")
        body = '<failure message="x"/>' if case in failing else ""
        rows.append(f'<testcase classname="{classname}" name="{name}">{body}</testcase>')
    return f'<testsuites><testsuite name="TestResults">{"".join(rows)}</testsuite></testsuites>'


class PackageTestResultsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.xunit_path = Path(directory.name) / "xunit.xml"
        self.swift_testing_path = Path(directory.name) / "xunit-swift-testing.xml"

    def check(self, test_filter="", swift_testing=None, xctest=None):
        if swift_testing is not None:
            self.swift_testing_path.write_text(swift_testing, encoding="utf-8")
        if xctest is not None:
            self.xunit_path.write_text(xctest, encoding="utf-8")
        expected = checker.expected_ids(LISTING, test_filter)
        return checker.problems(expected, checker.result_paths(self.xunit_path), test_filter)

    def test_every_listed_test_passing_is_complete(self):
        everything = xunit("ModA.FeedTests.first()", "ModA.FeedTests.second(_:)")
        self.assertEqual(
            self.check(swift_testing=everything, xctest=xunit("ModB.Outer.InnerTests.third()")),
            [],
        )

    def test_a_test_without_result_fails(self):
        found = self.check(swift_testing=xunit("ModA.FeedTests.first()", "ModB.Outer.InnerTests.third()"))
        self.assertEqual(len(found), 1)
        self.assertIn("ModA.FeedTests.second(_:)", found[0])

    def test_missing_or_truncated_result_file_fails(self):
        self.assertTrue(self.check())
        self.assertTrue(self.check(swift_testing="<testsuites><testsuite>"))

    def test_failures_and_unlisted_results_fail(self):
        all_cases = ("ModA.FeedTests.first()", "ModA.FeedTests.second(_:)", "ModB.Outer.InnerTests.third()")
        self.assertTrue(self.check(swift_testing=xunit(*all_cases, failing={"ModA.FeedTests.first()"})))
        self.assertTrue(self.check(swift_testing=xunit(*all_cases, "ModA.FeedTests.extra()")))

    def test_filter_selects_tests_through_any_enclosing_suite_or_module(self):
        self.assertEqual(self.check("FeedTests$", swift_testing=xunit("ModA.FeedTests.first()", "ModA.FeedTests.second(_:)")), [])
        self.assertEqual(self.check("Outer$", swift_testing=xunit("ModB.Outer.InnerTests.third()")), [])
        self.assertEqual(self.check("first", swift_testing=xunit("ModA.FeedTests.first()")), [])

    def test_filter_that_selects_nothing_fails(self):
        self.assertTrue(self.check("NoSuchTests", swift_testing=xunit()))


if __name__ == "__main__":
    unittest.main()
