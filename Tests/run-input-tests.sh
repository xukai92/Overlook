#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/overlook-input-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cat "$repo_dir/Overlook/InputManager.swift" "$repo_dir/Tests/InputManagerTests.swift" > "$test_dir/InputManagerUnderTest.swift"
swiftc -parse-as-library "$repo_dir/Overlook/JSONValue.swift" \
    "$repo_dir/Tests/InputTestStubs.swift" "$test_dir/InputManagerUnderTest.swift" \
    -o "$test_dir/input-tests"
"$test_dir/input-tests"
