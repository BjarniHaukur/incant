#!/bin/zsh
set -euo pipefail

# Builds dist/Incant.dmg: the app, an Applications folder to drag it onto, and a
# note for whoever opens it.
#
# Incant is ad-hoc signed, so `spctl --assess` rejects it and macOS will refuse
# to open it on any machine but the one that built it until the user overrides
# Gatekeeper by hand. The note in the image walks them through that. Signing
# with a Developer ID and notarizing is what removes the step entirely — see
# README.

root="${0:A:h}"
app="$root/dist/Incant.app"
staging="$root/.build/dmg"
dmg="$root/dist/Incant.dmg"

[[ -d "$app" ]] || "$root/build-app.sh"
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")

rm -rf "$staging" "$dmg"
mkdir -p "$staging" "$root/dist"
cp -R "$app" "$staging/Incant.app"
ln -s /Applications "$staging/Applications"

cat > "$staging/Open me first.txt" <<'NOTE'
Incant — dictation for macOS

1. Drag Incant onto the Applications folder here.

2. The first time you open it, macOS will say it cannot verify the developer.
   That is because this build is not signed with a paid Apple developer
   certificate, not because anything is wrong with it.

   Right-click Incant in Applications, choose Open, then click Open in the
   dialog. If there is no Open button, go to System Settings > Privacy &
   Security, scroll down, and click "Open Anyway" next to Incant.

   You only have to do this once.

3. Incant needs an OpenAI API key, which you paste into its settings window the
   first time it launches. It will also ask for Microphone access, and for
   Accessibility access so it can type words into whatever app you are using.

Press Command-Shift-Space to start dictating, and press it again to stop. The
words appear as you speak them.
NOTE

# One-step compressed image. Building read-write, setting a volume icon and
# calling `hdiutil convert` is the prettier recipe, but conversion of an
# attached image fails outright in sandboxed shells, and a disk icon is not
# worth a build step that breaks depending on where it runs.
hdiutil create -quiet -srcfolder "$staging" -volname "Incant" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg"
rm -rf "$staging"

print "$dmg ($version, $(du -h "$dmg" | cut -f1))"
