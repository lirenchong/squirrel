#!/usr/bin/env bash
# Offline fixture preparation/staging only. Xcode build auto-registers apps;
# stage a separately compiled disposable product, never build or register here.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
out="$root/build/synthetic-imk-probe"
info="$out/Info.plist"
fixture="$out/SharedSupport"
mode="${1:---prepare-only}"
if [[ "$mode" != --prepare-only && "$mode" != --stage-existing ]]; then
  echo 'Usage: scripts/build-synthetic-imk-probe.sh [--prepare-only|--stage-existing]' >&2
  exit 2
fi

if [[ -L "$root/build" || -L "$out" || -L "$fixture" || -L "$info" ||
      -L "$out/SyntheticTextHost-Info.plist" || -L "$out/DerivedData" || -L "$out/Products" ]]; then
  echo 'Refusing symlinked synthetic build path' >&2
  exit 2
fi
mkdir -p "$out" "$fixture"
python3 - "$root/resources/Info.plist" "$info" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
old = 'im.rime.inputmethod.Squirrel'
new = old + '.SyntheticTest'
modes = info['ComponentInputModeDict']
entries = modes['tsInputModeListKey']
for suffix in ('.Hans', '.Hant'):
    entry = entries.pop(old + suffix)
    entry['TISInputSourceID'] = new + suffix
    entries[new + suffix] = entry
modes['tsVisibleInputModeOrderedArrayKey'] = [new + '.Hans', new + '.Hant']
info.update(TISInputSourceID=new, CFBundleName='SquirrelSyntheticTest',
            CFBundleExecutable='SquirrelSyntheticTest',
            CFBundleDisplayName='Squirrel Synthetic IMK Probe',
            InputMethodConnectionName='Squirrel_SyntheticTest_Connection',
            SUEnableAutomaticChecks=False, SUEnableInstallerLauncherService=False,
            SyntheticIMKProbe=True)
info.pop('SUFeedURL', None)
info.pop('SUPublicEDKey', None)
with open(sys.argv[2], 'wb') as destination:
    plistlib.dump(info, destination)
assert info['TISInputSourceID'] == new
assert set(entries) == {new + '.Hans', new + '.Hant'}
assert not info['SUEnableAutomaticChecks'] and 'SUFeedURL' not in info
PY
python3 - "$out/SyntheticTextHost-Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'wb') as destination:
    plistlib.dump({'CFBundleIdentifier': 'com.example.SquirrelSyntheticTextHost',
                   'CFBundleExecutable': 'SyntheticTextHost', 'CFBundleName': 'SyntheticTextHost',
                   'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                   'NSPrincipalClass': 'NSApplication'}, destination)
PY
for file in default.yaml synthetic.schema.yaml synthetic.dict.yaml squirrel.yaml; do
  cp "$root/scripts/synthetic-rime/$file" "$fixture/$file"
done
python3 - "$fixture" <<'PY'
import os
import sys

expected = {'default.yaml', 'synthetic.schema.yaml', 'synthetic.dict.yaml', 'squirrel.yaml'}
assert set(os.listdir(sys.argv[1])) == expected, 'Unexpected synthetic shared data'
assert all(not os.path.islink(os.path.join(sys.argv[1], name)) for name in expected)
PY
plutil -lint "$info"
plutil -lint "$out/SyntheticTextHost-Info.plist"
echo "PREPARED synthetic-only plist and Rime shared data in $out"
if [[ "$mode" == --prepare-only ]]; then exit 0; fi

# No automatic downloads or live app fallback. Headers match the project's src search path.
for path in lib/librime.1.dylib librime/src/rime_api_stdbool.h \
            librime/src/rime/key_table.h bin/rime_deployer bin/rime_dict_manager \
            bin/rime-install; do
  if [[ ! -f "$root/$path" ]]; then echo "MISSING build dependency: $path" >&2; exit 3; fi
done
for path in Frameworks/Sparkle.framework data/plum data/opencc; do
  if [[ ! -d "$root/$path" ]]; then echo "MISSING build dependency: $path" >&2; exit 3; fi
done
developer_dir="/Applications/Xcode.app/Contents/Developer"
if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
  echo 'MISSING full Xcode; no build attempted' >&2
  exit 4
fi
if ! DEVELOPER_DIR="$developer_dir" xcodebuild -license check; then
  echo 'Xcode license requires human review/acceptance; no staging attempted' >&2
  exit 5
fi
app="$out/Products/SquirrelSyntheticTest.app"
[[ -d "$app/Contents/SharedSupport" && ! -L "$app" && ! -L "$app/Contents" &&
   ! -L "$app/Contents/SharedSupport" ]] || {
  echo 'Missing or symlinked build SharedSupport; refusing to package' >&2; exit 6;
}
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
base = 'im.rime.inputmethod.Squirrel.SyntheticTest'
assert info['CFBundleIdentifier'] == base
assert info['TISInputSourceID'] == base
assert info['CFBundleExecutable'] == 'SquirrelSyntheticTest'
assert info['InputMethodConnectionName'] == 'Squirrel_SyntheticTest_Connection'
assert info['SyntheticIMKProbe'] is True
assert info['SUEnableAutomaticChecks'] is False
assert info['SUEnableInstallerLauncherService'] is False
assert 'SUFeedURL' not in info
modes = info['ComponentInputModeDict']
entries = modes['tsInputModeListKey']
assert set(entries) == {base + '.Hans', base + '.Hant'}
assert modes['tsVisibleInputModeOrderedArrayKey'] == [base + '.Hans', base + '.Hant']
assert all(entry['TISInputSourceID'] == key for key, entry in entries.items())
assert info['InputMethodServerControllerClass'] == 'Squirrel.SquirrelInputController'
print('Verified isolated bundle IDs, connection, update policy, and controller class')
PY
executable="$app/Contents/MacOS/SquirrelSyntheticTest"
debug_dylib="$app/Contents/MacOS/SquirrelSyntheticTest.debug.dylib"
guard_binary="$executable"
if [[ -f "$debug_dylib" ]]; then
  otool -L "$executable" | grep -Fq '@rpath/SquirrelSyntheticTest.debug.dylib' || {
    echo 'Executable does not load the synthetic debug dylib' >&2; exit 6;
  }
  guard_binary="$debug_dylib"
fi
grep -aFq 'Synthetic IMK probe identity mismatch' "$guard_binary" || {
  echo 'Synthetic guard missing from compiled code; refusing to package' >&2; exit 6;
}
# Xcode compiles the production InfoPlist.xcstrings into localized Squirrel names.
# Override only the disposable product so the test source is visibly distinct.
python3 - "$app/Contents/Resources" <<'PY'
import os
import plistlib
import sys

resources = sys.argv[1]
base = 'im.rime.inputmethod.Squirrel.SyntheticTest'
labels = {'CFBundleName': 'Squirrel Synthetic IMK Probe',
          'CFBundleDisplayName': 'Squirrel Synthetic IMK Probe',
          base: 'Squirrel Synthetic IMK Probe',
          base + '.Hans': 'Squirrel Synthetic IMK Probe (Hans)',
          base + '.Hant': 'Squirrel Synthetic IMK Probe (Hant)'}
for name in os.listdir(resources):
    location = os.path.join(resources, name)
    if not name.endswith('.lproj'):
        continue
    assert os.path.isdir(location) and not os.path.islink(location)
    output = os.path.join(location, 'InfoPlist.strings')
    assert not os.path.islink(output)
    with open(output, 'wb') as destination:
        plistlib.dump(labels, destination)
PY
rm -rf "$app/Contents/SharedSupport" # only the verified disposable derived product
ditto "$fixture" "$app/Contents/SharedSupport"
codesign --force --deep --sign - "$app"
host="$out/SyntheticTextHost.app"
mkdir -p "$host/Contents/MacOS"
cp "$out/SyntheticTextHost-Info.plist" "$host/Contents/Info.plist"
swiftc -parse-as-library "$root/scripts/synthetic-imk-host.swift" "$root/scripts/synthetic-web-fixture.swift" \
  -o "$host/Contents/MacOS/SyntheticTextHost"
codesign --force --sign - "$host"
echo "STAGED isolated probe and synthetic host: $app / $host (not installed or run by this script)"
