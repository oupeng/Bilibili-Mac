# 由 run-quality-gates.sh 与 run-targeted-tests.sh source，不单独执行。
# 调用方先 cd 到仓库根并设置 artifact_root；SwiftPM／Xcode 只读写该任务临时根。

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [ ! -x "$developer_dir/usr/bin/xcodebuild" ]; then
    echo "需要完整 Xcode：$developer_dir" >&2
    exit 1
fi
export DEVELOPER_DIR="$developer_dir"

derived_data="$artifact_root/DerivedData"
mkdir -p "$artifact_root/tmp" "$artifact_root/ModuleCache.noindex"

# 用 $artifact_root/$1 作 HOME 运行其余参数组成的命令。
isolated() {
    isolated_home="$artifact_root/$1"
    shift
    mkdir -p "$isolated_home"
    env \
        HOME="$isolated_home" \
        CFFIXED_USER_HOME="$isolated_home" \
        XDG_CACHE_HOME="$isolated_home/.cache" \
        TMPDIR="$artifact_root/tmp" \
        CLANG_MODULE_CACHE_PATH="$artifact_root/ModuleCache.noindex" \
        SWIFTPM_MODULECACHE_OVERRIDE="$artifact_root/ModuleCache.noindex" \
        "$@"
}

# 在任务临时根里运行 `swift test`；参数原样接在 test 之后（含 list 子命令）。
swiftpm_test() {
    isolated swiftpm-home xcrun swift test "$@" \
        --package-path Packages/BiliKitCore \
        --scratch-path "$artifact_root/swiftpm" \
        --cache-path "$artifact_root/swiftpm-cache" \
        --config-path "$artifact_root/swiftpm-config" \
        --security-path "$artifact_root/swiftpm-security"
}

# 运行包测试并核对每个应运行的测试都有通过的结果。用法：package_test <筛选器，空串为全部> [swift test 参数…]
# 测试进程中途 exit(0) 时 swift test 仍返回 0，所以退出码之外再用 xUnit 结果与 `swift test list`
# 逐个比对（Scripts/check-package-test-results.py）；列表在测试之后取，复用同一次构建。
package_test() {
    package_test_filter=$1
    shift
    package_test_results="$artifact_root/package-test-results"
    rm -rf "$package_test_results"
    mkdir -p "$package_test_results"
    if [ -n "$package_test_filter" ]; then
        set -- "$@" --filter "$package_test_filter"
    fi
    swiftpm_test "$@" --xunit-output "$package_test_results/xunit.xml"
    swiftpm_test list --skip-build > "$package_test_results/list.txt"
    python3 -B Scripts/check-package-test-results.py \
        "$package_test_results/list.txt" \
        "$package_test_results/xunit.xml" \
        "$package_test_filter"
}

app_xcodebuild() {
    isolated xcode-home xcodebuild \
        -quiet \
        -project BiliKitMac.xcodeproj \
        -scheme BiliKitMac \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        -clonedSourcePackagesDirPath "$artifact_root/SourcePackages" \
        CODE_SIGNING_ALLOWED=NO \
        "$@"
}
