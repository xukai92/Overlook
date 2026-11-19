#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/overlook-window-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library "$repo_dir/Overlook/WindowGeometry.swift" \
    "$repo_dir/Tests/WindowGeometryTests.swift" -o "$test_dir/window-tests"
"$test_dir/window-tests"
