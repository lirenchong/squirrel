#!/usr/bin/env python3
"""Bounded synthetic-host test. Requires a fresh default-off test IME process.

The host activates itself, selects only the test source and restores its prior
source after eight seconds unless focus/source changed externally. No global
event posting, Accessibility, real document reads or live Rime changes.
"""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--case", choices=("full", "chinese", "line-end", "right-Han", "space", "blur", "arrow", "click"), default="full")
parser.add_argument("--variant", choices=("baseline", "L", "P"), default="baseline")
parser.add_argument("--action", choices=("preflight", "request", "verify"), default="preflight")
parser.add_argument("--run-id")
parser.add_argument("--installed-probe", type=pathlib.Path)
parser.add_argument("--controller-authorized", action="store_true")
parser.add_argument("--fresh-ime-confirmed", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
artifacts = root / ".amp/in/artifacts"
assert artifacts.is_dir() and artifacts.resolve() == artifacts, "Missing or symlinked receipt directory"
build = root / "build/synthetic-imk-probe" / args.variant
host = build / "SyntheticTextHost.app"
probe = build / "SquirrelSyntheticTest.app"
if args.variant != "baseline":
    assert args.case != "full", "Select one independent experimental case"
    assert host.is_dir() and probe.is_dir(), "Run the offline --build-remote builder first"
    assert host.resolve() == host and probe.resolve() == probe, "Symlinked product refused"
    info = plistlib.loads((probe / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "im.rime.inputmethod.Squirrel.SyntheticTest"
    assert info["SyntheticIMKProbe"] is True
    assert info["SyntheticSpacingVariant"] == args.variant, "Wrong compiled variant"
    binary = probe / "Contents/MacOS/SquirrelSyntheticTest"
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(probe)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(host)], check=True)
    if args.action == "preflight":
        print(f"PREPARED variant={args.variant} case={args.case}; no source selection or app launch")
        raise SystemExit(0)
    assert args.run_id and str(uuid.UUID(args.run_id)) == args.run_id, "Use a canonical UUID run ID"
    request = artifacts / f"request-{args.run_id}.json"
    receipt = artifacts / f"remote-{args.run_id}.json"
    assert request.resolve() == request and receipt.resolve() == receipt, "Symlinked receipt refused"
    if args.action == "request":
        assert args.controller_authorized and args.fresh_ime_confirmed, "Only the runtime owner may request a fresh default-off IME test"
        assert args.installed_probe, "Supply the controller-installed disposable probe path"
        installed = args.installed_probe.resolve()
        assert installed == pathlib.Path.home() / "Library/Input Methods/SquirrelSyntheticTest.app", "Must match the synthetic Main.swift appDir; never target formal Squirrel"
        assert (installed / "Contents/Info.plist").read_bytes() == (probe / "Contents/Info.plist").read_bytes()
        assert hashlib.sha256((installed / "Contents/MacOS/SquirrelSyntheticTest").read_bytes()).hexdigest() == digest
        assert not receipt.exists(), "Never reuse a receipt ID"
        with request.open("x") as output:
            json.dump(dict(runID=args.run_id, variant=args.variant, case=args.case, binarySHA256=digest,
                           evidence="request-only", freshIMEConfirmedByController=True), output)
        subprocess.run(["open", "-n", str(host), "--args", "--focus-test", "--spacing-test",
                        "--experiment-case", args.case, "--run-id", args.run_id], check=True)
        print(f"REQUESTED {args.run_id}; after the host restores/exits, run --action verify with the same variant/case/run-id")
        raise SystemExit(0)
    planned = json.loads(request.read_text())
    observed = json.loads(receipt.read_text())
    assert planned["runID"] == observed["runID"] == args.run_id
    assert planned["case"] == observed["case"] == args.case and planned["variant"] == args.variant
    assert planned["binarySHA256"] == digest, "Build changed after request"
    assert observed["evidence"] == "remote-synthetic-NSTextView"
    print(json.dumps(observed, ensure_ascii=False, indent=2))
    assert observed.get("restored") is True, "Restore unconfirmed: inspect current source before any cleanup"
    assert observed.get("complete") is True, "Incomplete request, not proof"
    for field in ("textMatches", "caretMatches", "markClear", "oneUndoMatches", "eventBoundary"):
        assert observed.get(field) is True, f"Strict contract failed: {field}"
    assert observed.get("undoRemaining") is False, "Hidden extra Undo transaction"
    movement = args.case in ("arrow", "click")
    assert observed.get("userMoved") is movement
    assert observed.get("scope") == ("user-movement" if movement else "unmoved-completion")
    assert observed.get("pass") is True, "Strict text/caret/clear-mark/single-host-Undo contract failed"
    print(f"PASS one remote synthetic {'movement' if movement else 'unmoved-completion'} case only; TextEdit/WebKit/Chrome/WeChat still pending")
    raise SystemExit(0)

# Preserve the baseline diagnostic, but do not launch on the default command.
assert args.case in ("full", "chinese")
if args.action != "request":
    print("Baseline request requires --action request --controller-authorized --fresh-ime-confirmed")
    raise SystemExit(0)
assert args.controller_authorized and args.fresh_ime_confirmed
output = root / f".amp/in/artifacts/remote-suite-{args.case}.log"
assert host.is_dir() and output.parent.is_dir()
predicate = (
    '(subsystem == "im.rime.inputmethod.Squirrel.SyntheticTest" AND category == "lifecycle")'
    ' OR (subsystem == "com.example.SquirrelSyntheticTextHost" AND category == "fixture")'
)
with output.open("w") as log:
    reader = subprocess.Popen(
        ["/usr/bin/log", "stream", "--style", "compact", "--level", "debug", "--predicate", predicate],
        stdout=log, stderr=subprocess.STDOUT,
    )
    try:
        time.sleep(1)
        command = ["open", "-n", str(host), "--args", "--focus-test", "--spacing-test", "--capture"]
        if args.case == "chinese":
            command.append("--chinese-only")
        subprocess.run(command, check=True)
        time.sleep(12)
    finally:
        reader.terminate()
        reader.wait(timeout=3)
text = output.read_text()
for line in text.splitlines():
    if "spacing phase=" in line or "focusTestRestored=" in line:
        print(line)
assert "phase=suiteComplete pass=true" in text, "Suite incomplete; see bounded receipt"
assert "pass=false" not in text, "An assertion failed; do not continue this write path"
assert "focusTestRestored=true" in text, "Restore not confirmed; inspect current source before cleanup"
print("PASS remote IMK transport (not physical keystrokes or third-party applications)")
