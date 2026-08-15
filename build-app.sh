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

# A Developer ID signature with the hardened runtime is what notarization needs,
# and it carries a stable designated requirement of its own, so Accessibility
# approval survives rebuilds without the hand-written one the ad-hoc path needs.
# Set INCANT_SIGN_IDENTITY to choose among several certificates.
identity=${INCANT_SIGN_IDENTITY:-$(
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }'
)}

if [[ -n "$identity" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements "$root/Resources/Incant.entitlements" \
    --sign "$identity" \
    "$app_dir"
  print "signed: $identity"
else
  # Ad-hoc signing defaults to the binary's changing CDHash, which makes macOS
  # forget Accessibility approval on every rebuild, hence the fixed requirement.
  codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.bjarni.Incant"' \
    "$app_dir"
  print "ad-hoc signed — no Developer ID certificate found, see README"
fi
print "$app_dir"
