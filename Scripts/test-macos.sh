#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/花妖桌宠.app}"
ZSTD="$(command -v zstd)" || { echo "Install the zstd CLI before running the tests." >&2; exit 1; }
codesign --verify --deep --strict "$APP"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/huayao-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TEST_CONTENTS="$WORK/UsageTest.app/Contents"
mkdir -p "$TEST_CONTENTS/MacOS"
cp -R "$APP/Contents/Resources" "$APP/Contents/Helpers" "$TEST_CONTENTS/"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string HarnessUsageSmoke' "$TEST_CONTENTS/Info.plist"

sources=()
for source in "$ROOT"/Sources/HuaYaoPet/*.swift; do
  if [[ "$source" != */main.swift ]]; then
    sources+=("$source")
  fi
done

ulimit -c 0
for spec in "$ROOT"/Tests/*.swift; do
  name="$(basename "$spec" .swift)"
  if [[ "$name" == HarnessUsageSmoke ]]; then
    binary="$TEST_CONTENTS/MacOS/$name"
    swiftc -parse-as-library "${sources[@]}" "$spec" -o "$binary"
    "$binary" "$ROOT/Tests/Fixtures/HarnessUsage.json" "$ZSTD"
  else
    swiftc -parse-as-library "${sources[@]}" "$spec" -o "$WORK/$name"
    "$WORK/$name"
  fi
done
