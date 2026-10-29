#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/polarpap-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos14.0 -module-cache-path "$test_dir/cache" Sources/SignalCore.swift Sources/TimeShift.swift Sources/Sessions.swift Tests/CoreTests.swift -o "$test_dir/core-tests"
"$test_dir/core-tests"
