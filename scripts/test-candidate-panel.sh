#!/bin/bash
# Offline swiftc build; direct process execution only, no LS/IME registration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
deps="$root/../squirrel"
owner="${SUPPRESSION_SOURCE:-/Users/chong/Project/agent-reliability-imk-delete-mac-20261013/subprojects/input-keyboard}"
runtime="${RIME_RUNTIME:-/Library/Input Methods/Squirrel.app/Contents/Frameworks}"
mode="${1:-normal}"
case "$mode" in normal|page|failure|mismatch|unsupported) ;; *) exit 2 ;; esac
mkdir -p "$root/.amp/in"
out="$(mktemp -d "$root/.amp/in/panel-$mode.XXXXXX")"
app="$out/PanelTests.app"
[[ ! -L "$out" && ! -L "$app" ]] || exit 2
mkdir -p "$app/Contents/"{MacOS,Frameworks,SharedSupport} "$out/profile/lua" "$root/.amp/in/artifacts"
ditto "$deps/Frameworks/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
cp "$runtime/librime.1.dylib" "$app/Contents/Frameworks/"
if [[ -f "$runtime/rime-plugins/librime-lua.dylib" ]]; then
  cp "$runtime/rime-plugins/librime-lua.dylib" "$app/Contents/Frameworks/"
fi
python3 - "$app" "$out/profile" "$owner" "$mode" <<'PY'
import pathlib, plistlib, shutil, sys
app, profile, source = map(pathlib.Path, sys.argv[1:4]); mode = sys.argv[4]
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='im.rime.inputmethod.Squirrel.PanelTests', CFBundleExecutable='PanelTests', CFBundleVersion='1', CFBundlePackageType='APPL'), f)
for p in (source/'tests/fixtures/rime_candidate_suppression').glob('*.dict.yaml'):
    shutil.copy(p, profile/p.name)
shutil.copy(source/'lua/rime_candidate_suppression.lua', profile/'lua/rime_candidate_suppression.lua')
schema = (source/'tests/fixtures/rime_candidate_suppression/synthetic.schema.yaml').read_text()
schema = schema.replace('processors: [', 'processors: [lua_processor@suppression_processor, ')
schema = schema.replace('filters: [uniquifier]', 'filters: [uniquifier, lua_filter@runtime_trace, lua_filter@suppression_filter]')
schema = schema.replace('page_size: 9', 'page_size: '+('1' if mode == 'page' else '9'))
schema += '\ncandidate_suppression:\n  path: '+str(profile/'suppressed.tsv')+'\n'
if mode == 'unsupported':
    schema = schema.replace('translators: [script_translator]', 'translators: [table_translator@custom_phrase, script_translator]')
    schema += '\ncustom_phrase:\n  dictionary: ""\n  user_dict: custom_phrase\n  db_class: stabledb\n  enable_completion: false\n  enable_sentence: false\n'
    (profile/'custom_phrase.txt').write_text('孤舟\tzz\t9\n')
(profile/'synthetic.schema.yaml').write_text(schema)
(profile/'synthetic_other.schema.yaml').write_text(schema.replace('schema_id: synthetic', 'schema_id: synthetic_other'))
(profile/'default.yaml').write_text('config_version: "1"\nschema_list:\n  - schema: synthetic\n')
(profile/'squirrel.yaml').write_text('config_version: "1"\nshow_notifications_when: never\nstyle:\n  inline_preedit: false\n  inline_candidate: false\n')
(profile/'rime.lua').write_text('local s = require("rime_candidate_suppression")\nsuppression_processor = s.processor\nsuppression_filter = s.filter\nruntime_trace = {func=function(input, env) env.engine.context:set_property("panel_lua_runtime", _VERSION); for cand in input:iter() do yield(cand) end end}\n')
if mode == 'failure':
    (profile/'suppressed.tsv.tmp').mkdir(exist_ok=True)
PY
sources=()
for file in "$root/sources/"*.swift; do [[ "${file##*/}" == Main.swift ]] || sources+=("$file"); done
swiftc -parse-as-library -enable-bare-slash-regex -D SYNTHETIC_IMK_PROBE -module-name Squirrel \
  -import-objc-header "$root/scripts/test-candidate-panel.h" \
  -I "$deps/librime/src" -I "$deps/librime/include" -F "$deps/Frameworks" \
  -L "$app/Contents/Frameworks" -lrime.1 -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "${sources[@]}" "$root/scripts/test-candidate-panel.swift" -o "$app/Contents/MacOS/PanelTests"
codesign --force --deep --sign - "$app"
"$app/Contents/MacOS/PanelTests" "$mode"
