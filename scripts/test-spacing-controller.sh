#!/usr/bin/env bash
# Build a standalone synthetic app without Xcode/LaunchServices registration,
# input-source switching, installation, accessibility, or event posting.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$root/build/synthetic-imk-probe"
app="$out/ControllerTests.app"
[[ ! -L "$root/build" && ! -L "$out" && ! -L "$app" ]] || exit 2
mkdir -p "$app/Contents/MacOS" "$app/Contents/SharedSupport" "$app/Contents/Frameworks"
cp "$root/scripts/synthetic-rime/"*.yaml "$app/Contents/SharedSupport/"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump(dict(CFBundleIdentifier='im.rime.inputmethod.Squirrel.SyntheticControllerTests',
                      CFBundleExecutable='ControllerTests', CFBundleVersion='1', CFBundlePackageType='APPL'), output)
PY
ditto "$root/Frameworks/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$root/lib/librime.1.dylib" "$app/Contents/Frameworks/"
sources=()
for source in "$root/sources/"*.swift; do
  [[ "$(basename "$source")" == Main.swift ]] || sources+=("$source")
done
swiftc -parse-as-library -enable-bare-slash-regex -D SYNTHETIC_IMK_PROBE -module-name Squirrel \
  -import-objc-header "$root/sources/Squirrel-Bridging-Header.h" \
  -I "$root/librime/src" -I "$root/librime/include" \
  -F "$root/Frameworks" -L "$root/lib" -lrime.1 \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${sources[@]}" "$root/scripts/test-spacing-controller.swift" \
  -o "$app/Contents/MacOS/ControllerTests"
codesign --force --deep --sign - "$app"
"$app/Contents/MacOS/ControllerTests" "$@"
