#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "$0")/.." && pwd)"
release="${1:-$plugin/../Harness 插件发布包}"
mkdir -p "$release"
release="$(cd "$release" && pwd)"
package="$(mktemp -d "${TMPDIR:-/tmp}/huayao-harness-package.XXXXXX")"
trap 'rm -rf "$package"' EXIT
mkdir -p "$package/lib"
cd "$plugin"
python3 scripts/prepare-art.py
python3 ../Scripts/audit-portraits.py --harness src/portraits.generated.json
esbuild=(npx --yes esbuild@0.25.12)
if [ -n "${ESBUILD_BIN:-}" ]; then
  esbuild=("$ESBUILD_BIN")
fi
"${esbuild[@]}" src/client.jsx --bundle --format=cjs --platform=browser \
  --target=chrome132 --jsx=automatic --external:react --loader:.css=text --loader:.txt=text \
  --banner:js='window.__ModuleLoader__.load({id:"huayao-harness-pet",factory:require=>{const module={exports:{}};' \
  --footer:js='return module.exports}});' \
  --outfile="$package/lib/client.js"
cp src/host.js "$package/lib/host.js"
cp package.json cordis.patch.yml README.md "$package/"
cp -R locale "$package/"
cp ../LICENSE "$package/LICENSE"
cp ../NOTICE-ARTWORK.zh-CN.txt "$package/"
cd "$package"
npm pack --ignore-scripts --pack-destination "$release"
