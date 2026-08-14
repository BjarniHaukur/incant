#!/bin/zsh
set -euo pipefail

root="${0:A:h}"
build_dir="$root/.build/release"
app_dir="$root/dist/Incant.app"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
export CLANG_MODULE_CACHE_PATH=/tmp/incant-clang-cache

cd "$root"
swift build -c release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/Incant" "$app_dir/Contents/MacOS/Incant"
cp "$root/Resources/Info.plist" "$app_dir/Contents/Info.plist"

swift "$root/Resources/make-icon.swift" "$root/.build/AppIcon-1024.png"
cp "$root/.build/AppIcon-1024.png" "$app_dir/Contents/Resources/AppIcon.png"

# Embed a stable designated requirement. Plain ad-hoc signing defaults to the
# binary's changing CDHash, which makes macOS forget Accessibility approval on
# every rebuild.
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.bjarni.PushType"' \
  "$app_dir"
print "$app_dir"
