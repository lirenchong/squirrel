#!/bin/bash
# Offline swiftc build; direct process execution only, no LS/IME registration.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
deps="$root/../squirrel"
owner="${SUPPRESSION_SOURCE:-/Users/chong/Project/agent-reliability-imk-delete-mac-20261013/subprojects/input-keyboard}"
runtime="${RIME_RUNTIME:-/Library/Input Methods/Squirrel.app/Contents/Frameworks}"
mode="${1:-normal}"
case "$mode" in normal|page|failure|mismatch|unsupported|restore|restore-large|restore-wire|restore-old|restore-learning|restore-page|rc-reading|rc-page|rc-unicode|rc-missing) ;; *) exit 2 ;; esac
# Test-source fixed point, not a production runtime/version gate.
owner_head="$(git -C "$owner" rev-parse HEAD)"
[[ ( "$owner_head" == ed272d0d81838a5cfebac86f41c8462cd949b5f2 ||
     "$owner_head" == 770080fefea296b66fe5e6dc3d3d73016eb5eee7 ) &&
   -z "$(git -C "$owner" status --porcelain)" ]] || { echo 'Wrong or dirty suppression pairing' >&2; exit 2; }
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
python3 -B - "$app" "$out/profile" "$owner" "$mode" <<'PY'
import hashlib, importlib.util, json, pathlib, plistlib, shutil, subprocess, sys
app, profile, source = map(pathlib.Path, sys.argv[1:4]); mode = sys.argv[4]
with (app/'Contents/Info.plist').open('wb') as f:
    plistlib.dump(dict(CFBundleIdentifier='im.rime.inputmethod.Squirrel.PanelTests', CFBundleExecutable='PanelTests', CFBundleVersion='1', CFBundlePackageType='APPL'), f)
for p in (source/'tests/fixtures/rime_candidate_suppression').glob('*.dict.yaml'):
    shutil.copy(p, profile/p.name)
shutil.copy(source/'lua/rime_candidate_suppression.lua', profile/'lua/rime_candidate_suppression.lua')
if mode == 'restore-old':
    old = subprocess.check_output(['git', '-C', str(source), 'show',
        'e99e103ba32b3ce4ace17bc722e411bca64f5a50:subprojects/input-keyboard/lua/rime_candidate_suppression.lua'])
    (profile/'lua/rime_candidate_suppression.lua').write_bytes(old)
schema = (source/'tests/fixtures/rime_candidate_suppression/synthetic.schema.yaml').read_text()
schema = schema.replace('processors: [', 'processors: [lua_processor@suppression_processor, ')
schema = schema.replace('filters: [uniquifier]', 'filters: [uniquifier, lua_filter@runtime_trace, lua_filter@suppression_filter]')
schema = schema.replace('page_size: 9', 'page_size: '+('2' if mode == 'rc-page' else '1' if mode in ('page', 'restore-page') else '9'))
schema += '\ncandidate_suppression:\n  path: '+str(profile/'suppressed.tsv')+'\n'
if mode == 'unsupported':
    schema = schema.replace('translators: [script_translator]', 'translators: [table_translator@custom_phrase, script_translator]')
    schema += '\ncustom_phrase:\n  dictionary: ""\n  user_dict: custom_phrase\n  db_class: stabledb\n  enable_completion: false\n  enable_sentence: false\n'
    (profile/'custom_phrase.txt').write_text('孤舟\tzz\t9\n')
if mode.startswith('rc-'):
    rows = {'rc-reading': '行\txk\t1\treading=hang\n',
            'rc-page': '孤舟\txk\t3\treading=gu zhou\n',
            'rc-unicode': '🧪\tem\t1\treading=lü\n',
            'rc-missing': '行\txk\t1\treading=hang\n无音\tap\t1\n'}[mode]
    editable = profile/'anonymous_editable_rc.tsv'
    editable.write_text(rows, encoding='utf-8')
    dictionary = profile/'anonymous_readings.dict.yaml'
    dictionary.write_text('---\nname: anonymous_readings\nversion: "1"\n...\n'
                          '甲\txing\n乙\thang\n丙\tgu zhou\n丁\tlü\n', encoding='utf-8')
    spec = importlib.util.spec_from_file_location('panel_rc_compiler', source/'scripts/compile_custom_phrase_rc.py')
    compiler = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = compiler
    spec.loader.exec_module(compiler)
    receipt = compiler.compile_reading_generation(editable, profile/'unused_target.txt', dictionary)
    assert hashlib.sha256(pathlib.Path(receipt['path']).read_bytes()).hexdigest() == receipt['digest']
    (profile/'anonymous_generation.json').write_text(json.dumps(receipt))
    print('anonymous compiler generation:', receipt)
    shutil.copy(source/'lua/custom_phrase_position_filter.lua', profile/'lua/pin.lua')
    schema = schema.replace('translators: [script_translator]', 'translators: [table_translator@custom_phrase, script_translator]')
    schema = schema.replace('filters: [uniquifier, lua_filter@runtime_trace, lua_filter@suppression_filter]',
        'filters: [lua_filter@pin, uniquifier, lua_filter@runtime_trace, lua_filter@rc_trace, lua_filter@suppression_filter, lua_filter@rc_final_trace]')
    schema += '\ncustom_phrase:\n  dictionary: ""\n  user_dict: '+receipt['user_dict']+'\n  db_class: stabledb\n  enable_completion: false\n  enable_sentence: false\n'
    # Explicit anonymous source even for pin fallback; never use default RC.
    schema += '\ncustom_phrase_position_filter:\n  source: '+receipt['path']+'\n'
(profile/'synthetic.schema.yaml').write_text(schema)
(profile/'synthetic_other.schema.yaml').write_text(schema.replace('schema_id: synthetic', 'schema_id: synthetic_other'))
(profile/'default.yaml').write_text('config_version: "1"\nschema_list:\n  - schema: synthetic\n')
(profile/'squirrel.yaml').write_text('config_version: "1"\nshow_notifications_when: never\nstyle:\n  inline_preedit: false\n  inline_candidate: false\n')
(profile/'rime.lua').write_text('local s = require("rime_candidate_suppression")\nsuppression_processor = s.processor\nsuppression_filter = s.filter\nruntime_trace = {func=function(input, env) env.engine.context:set_property("panel_lua_runtime", _VERSION); for cand in input:iter() do yield(cand) end end}\n')
if mode.startswith('rc-'):
    with (profile/'rime.lua').open('a') as f:
        f.write('''
pin = require("pin")
local function describe(genuine, env)
  local phrase = genuine:to_phrase()
  local code, text, err = s.candidate_identity(genuine, env)
  return genuine.type .. "|" .. (phrase and phrase.lang_name or "-") .. "|" ..
    (phrase and phrase.entry.custom_code or "-") .. "|" .. (code or err) .. "|" .. (text or genuine.text)
end
rc_trace = {init=s.init, fini=s.fini, func=function(input, env)
  local rows = {}
  env.engine.context:set_property("rc_binding", env.suppression_rc.error or "ok")
  env.engine.context:set_property("rc_identities", "")
  for cand in input:iter() do
    for _, genuine in ipairs(s.genuines(cand)) do rows[#rows+1] = describe(genuine, env) end
    env.engine.context:set_property("rc_identities", table.concat(rows, ";"))
    yield(cand)
  end
end}
-- Observation only: suppression remains the final mutating filter.
rc_final_trace = {init=s.init, fini=s.fini, func=function(input, env)
  local rows = {}
  env.engine.context:set_property("rc_final", "")
  for cand in input:iter() do
    for _, genuine in ipairs(s.genuines(cand)) do rows[#rows+1] = describe(genuine, env) end
    env.engine.context:set_property("rc_final", table.concat(rows, ";"))
    yield(cand)
  end
end}
''')
if mode == 'restore-wire':
    # Deliberately corrupt only public response properties in this anonymous
    # transport fixture. The canonical backend remains the unchanged writer.
    with (profile/'rime.lua').open('a') as f:
        f.write('''
local original = s.processor.func
suppression_processor = {init=s.processor.init, fini=s.processor.fini, func=function(key, env)
  local ctx = env.engine.context
  local action = ctx:get_property("suppression_action")
  local handled = original(key, env)
  local fault = ctx:get_property("panel_wire_fault")
  if action == "list" and fault ~= "" and ctx:get_property("suppression_result") == "ok" then
    local payload = ctx:get_property("suppression_entries")
    if fault == "short" then ctx:set_property("suppression_entries_bytes", tostring(#payload - 1)); return handled end
    if fault == "long" then ctx:set_property("suppression_entries_bytes", tostring(#payload + 1)); return handled end
    if fault == "metadata" then ctx:set_property("suppression_entries_bytes", string.rep("9", 128)); return handled end
    if fault == "overflow" then ctx:set_property("suppression_entries_bytes", "18446744073709551616"); return handled end
    if fault == "allocation" then ctx:set_property("suppression_entries_bytes", "9223372036854775806"); return handled end
    local header = "# rime-candidate-suppression-v1\\n"
    local rows = {utf8="xing\\t" .. string.char(255) .. "\\n", escape="xing\\t%41\\n",
      lower="xing\\t%0a\\n", duplicate="xing\\t行\\nxing\\t行\\n",
      order="xing\\t行\\nhang\\t行\\n", blank="\\n", tab="xing\\t行\\textra\\n",
      fold=" xing\\t行\\n", ["fold-accent"]=" ́xing\\t行\\n",
      empty="xing\\t\\n", nul="xing\\t" .. string.char(0) .. "\\n"}
    payload = header .. (rows[fault] or "xing\\t行\\n")
    if fault == "header" then payload = "wrong\\n" .. payload end
    if fault == "tail" then payload = payload:sub(1, -2) end
    ctx:set_property("suppression_entries", payload)
    ctx:set_property("suppression_entries_bytes", tostring(#payload))
  end
  return handled
end}
''')
if mode == 'restore-large':
    rows = [f'shu cai\t匿名{i:04d}%25%09%0D%0A🧪\n'.encode() for i in range(600)]
    rows += ['lü%25\t百分%25号\n'.encode(), 'xing\t行\n'.encode(), 'hang\t行\n'.encode()]
    (profile/'suppressed.tsv').write_bytes(b'# rime-candidate-suppression-v1\n'+b''.join(sorted(rows)))
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
