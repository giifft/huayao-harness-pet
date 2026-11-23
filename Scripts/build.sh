#!/bin/bash
# 把桌宠编译成可双击运行的 macOS .app
# 用法：bash Scripts/build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/花妖桌宠.app"
STAGING="$(mktemp -d "$ROOT/.huayao-build.XXXXXX")"
BUILT_APP="$STAGING/花妖桌宠.app"
PREVIOUS_APP="$STAGING/previous.app"
CONTENTS="$BUILT_APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

cleanup() {
  if [ -e "$PREVIOUS_APP" ] && [ ! -e "$APP" ]; then
    mv "$PREVIOUS_APP" "$APP" || return
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$MACOS" "$RES" "$CONTENTS/Helpers"

echo "==> 编译 Swift"
swiftc -O -parse-as-library \
  -target arm64-apple-macosx13.0 \
  -o "$MACOS/HuaYaoPet" \
  "$ROOT"/Sources/HuaYaoPet/*.swift

echo "==> 编译 Harness 解压组件"
ZSTD_SOURCE_DIR="${ZSTD_SOURCE_DIR:-}"
if [ -z "$ZSTD_SOURCE_DIR" ]; then
  ZSTD_ARCHIVE="$STAGING/zstd.tar.gz"
  curl -fLsS --retry 2 --max-time 30 \
    https://codeload.github.com/facebook/zstd/tar.gz/refs/tags/v1.5.7 -o "$ZSTD_ARCHIVE"
  echo "37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3  $ZSTD_ARCHIVE" | shasum -a 256 -c -
  tar -xf "$ZSTD_ARCHIVE" -C "$STAGING"
  ZSTD_SOURCE_DIR="$STAGING/zstd-1.5.7"
fi
xcrun clang -O2 -target arm64-apple-macosx13.0 -DZSTD_DISABLE_ASM \
  -I"$ZSTD_SOURCE_DIR/lib" "$ROOT/Sources/DSHDecoder/main.c" \
  "$ZSTD_SOURCE_DIR"/lib/common/*.c "$ZSTD_SOURCE_DIR"/lib/decompress/*.c \
  -o "$CONTENTS/Helpers/dsh-unzstd"
cp "$ZSTD_SOURCE_DIR/LICENSE" "$RES/Zstandard-LICENSE.txt"
codesign --sign - "$CONTENTS/Helpers/dsh-unzstd"

echo "==> 拷贝素材"
cp -R "$ROOT/Resources/Pets" "$RES/Pets"

echo "==> 写 Info.plist"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>花妖桌宠</string>
  <key>CFBundleDisplayName</key>       <string>花妖桌宠</string>
  <key>CFBundleIdentifier</key>        <string>local.huayao.desktoppet</string>
  <key>CFBundleVersion</key>           <string>1.2.0</string>
  <key>CFBundleShortVersionString</key><string>1.2.0</string>
  <key>CFBundleExecutable</key>        <string>HuaYaoPet</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> 应用图标"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon.icns" "$CONTENTS/Info.plist" 2>/dev/null || true
fi

echo "==> 验证并替换应用"
plutil -lint "$CONTENTS/Info.plist"
codesign --sign - "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
if [ -e "$APP" ]; then
  mv "$APP" "$PREVIOUS_APP"
fi
mv "$BUILT_APP" "$APP"

echo "完成：$APP"
echo "运行：open \"$APP\""
