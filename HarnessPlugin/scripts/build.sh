#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "$0")/.." && pwd)"
release="${1:-$plugin/../Harness 插件发布包}"
mkdir -p "$release" "$plugin/lib"
release="$(cd "$release" && pwd)"
cd "$plugin"
python3 scripts/prepare-art.py
esbuild=(npx --yes esbuild@0.25.12)
if [ -n "${ESBUILD_BIN:-}" ]; then
  esbuild=("$ESBUILD_BIN")
fi
"${esbuild[@]}" src/client.jsx --bundle --format=cjs --platform=browser \
  --target=chrome132 --jsx=automatic --external:react --loader:.css=text \
  --banner:js='window.__ModuleLoader__.load({id:"huayao-harness-pet",factory:require=>{const module={exports:{}};' \
  --footer:js='return module.exports}});' \
  --outfile=lib/client.js
cp src/host.js lib/host.js
npm pack --ignore-scripts --pack-destination "$release"
