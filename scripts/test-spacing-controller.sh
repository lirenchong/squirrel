#!/usr/bin/env bash
# Build a standalone synthetic app without Xcode/LaunchServices registration,
# input-source switching, installation, accessibility, or event posting.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
variant=baseline
dependencies="$root"
build_only=false
remote=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant) variant="$2"; shift 2 ;;
    --dependencies) dependencies="$2"; shift 2 ;;
    --build-only) build_only=true; shift ;;
    --build-remote) remote=true; build_only=true; shift ;;
    *) break ;;
  esac
done
flags=(-D SYNTHETIC_IMK_PROBE)
case "$variant" in
  baseline) ;;
  L) flags+=(-D SYNTHETIC_SPACING_L) ;;
  P) flags+=(-D SYNTHETIC_SPACING_P) ;;
  *) echo 'Expected --variant baseline|L|P' >&2; exit 2 ;;
esac
# Dependencies are read-only inputs; never fetch, build, or modify their tree.
for path in Frameworks/Sparkle.framework lib/librime.1.dylib librime/src/rime_api_stdbool.h; do
  [[ -e "$dependencies/$path" ]] || { echo "Missing read-only dependency: $path" >&2; exit 2; }
done
out="$root/build/synthetic-imk-probe/$variant"
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
ditto "$dependencies/Frameworks/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$dependencies/lib/librime.1.dylib" "$app/Contents/Frameworks/"
sources=()
for source in "$root/sources/"*.swift; do
  [[ "$(basename "$source")" == Main.swift ]] || sources+=("$source")
done
swiftc -parse-as-library -enable-bare-slash-regex "${flags[@]}" -module-name Squirrel \
  -import-objc-header "$root/sources/Squirrel-Bridging-Header.h" \
  -I "$dependencies/librime/src" -I "$dependencies/librime/include" \
  -F "$dependencies/Frameworks" -L "$dependencies/lib" -lrime.1 \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${sources[@]}" "$root/scripts/test-spacing-controller.swift" \
  -o "$app/Contents/MacOS/ControllerTests"
codesign --force --deep --sign - "$app"
if $remote; then
  # Preparation only. No Xcode, LaunchServices, install, IME start or TIS calls.
  bash "$root/scripts/build-synthetic-imk-probe.sh" --prepare-only
  probe="$out/SquirrelSyntheticTest.app"
  host="$out/SyntheticTextHost.app"
  mkdir -p "$probe/Contents/MacOS" "$host/Contents/MacOS"
  cp "$root/build/synthetic-imk-probe/Info.plist" "$probe/Contents/Info.plist"
  cp "$root/build/synthetic-imk-probe/SyntheticTextHost-Info.plist" "$host/Contents/Info.plist"
  python3 - "$probe/Contents/Info.plist" "$variant" <<'PY'
import plistlib, sys
path, variant = sys.argv[1:]
with open(path, 'rb') as source:
    info = plistlib.load(source)
# The prepared plist is an Xcode template; swiftc does not expand its variables.
info['CFBundleIdentifier'] = 'im.rime.inputmethod.Squirrel.SyntheticTest'
info['CFBundleVersion'] = '1'
info['SyntheticSpacingVariant'] = variant
with open(path, 'wb') as output:
    plistlib.dump(info, output)
PY
  ditto "$app/Contents/Frameworks" "$probe/Contents/Frameworks"
  ditto "$app/Contents/SharedSupport" "$probe/Contents/SharedSupport"
  swiftc -parse-as-library -enable-bare-slash-regex "${flags[@]}" -module-name Squirrel \
    -import-objc-header "$root/sources/Squirrel-Bridging-Header.h" \
    -I "$dependencies/librime/src" -I "$dependencies/librime/include" \
    -F "$dependencies/Frameworks" -L "$dependencies/lib" -lrime.1 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${sources[@]}" "$root/sources/Main.swift" -o "$probe/Contents/MacOS/SquirrelSyntheticTest"
  swiftc -parse-as-library "$root/scripts/synthetic-imk-host.swift" "$root/scripts/synthetic-web-fixture.swift" \
    -o "$host/Contents/MacOS/SyntheticTextHost"
  codesign --force --deep --sign - "$probe"
  codesign --force --sign - "$host"
  echo "PREPARED $probe / $host; controller owns registration, running and rollback"
fi
if ! $build_only; then "$app/Contents/MacOS/ControllerTests" "$@"; fi
