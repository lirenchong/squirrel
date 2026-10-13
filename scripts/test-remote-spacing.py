#!/usr/bin/env python3
"""Bounded synthetic-host test. Requires a fresh default-off test IME process.

The host activates itself, selects only the test source and restores its prior
source after eight seconds unless focus/source changed externally. No global
event posting, Accessibility, real document reads or live Rime changes.
"""
import argparse
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--case", choices=("full", "chinese"), default="full")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
host = root / "build/synthetic-imk-probe/SyntheticTextHost.app"
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
