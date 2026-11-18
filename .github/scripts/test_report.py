"""Sums up a test run for the job's summary and annotations (readable through the
checks API): every failed test with why, from the result bundle; or, when nothing
ran, the compiler's errors from the log.

Usage: test_report.py Tests.xcresult test.log"""
import json
import os
import re
import subprocess
import sys

bundle, log = sys.argv[1], sys.argv[2]


def annotate(kind, title, message):
    message = message.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
    print(f"::{kind} title={title}::{message}")


def summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as out:
            out.write("\n".join(lines) + "\n")


tests = None
if os.path.isdir(bundle):
    try:
        tests = json.loads(subprocess.check_output(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle], text=True))
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"Couldn't read {bundle}: {error}", file=sys.stderr)

def compiler_errors():
    text = open(log, errors="replace").read() if os.path.exists(log) else ""
    errors = sorted(set(re.findall(r"^.*\.swift:\d+:\d+: error: .*$", text, re.M)))
    errors = [line.replace(os.getcwd() + "/", "") for line in errors][:60]
    annotate("error", "Tests didn't run", "\n".join(errors) or text[-3000:])
    summary(["## Tests didn't run", "```", *errors, "```"])
    sys.exit(0)


if tests is None:
    compiler_errors()

passed, failed, skipped = 0, [], 0


def walk(node, path):
    global passed, skipped
    kind = node.get("nodeType")
    name = node.get("name", "")
    children = node.get("children", [])
    if kind == "Test Case":
        result = node.get("result")
        if result == "Passed":
            passed += 1
        elif result == "Skipped":
            skipped += 1
        elif result in ("Failed", "Expected Failure") and result != "Expected Failure":
            why = []
            for child in children:
                if child.get("nodeType") == "Failure Message":
                    why.append(child.get("name", ""))
                for grandchild in child.get("children", []):
                    if grandchild.get("nodeType") == "Failure Message":
                        why.append(f"{child.get('name', '')}: {grandchild.get('name', '')}")
            failed.append((" / ".join(path + [name]), why))
        return
    for child in children:
        walk(child, path + ([name] if kind in ("Test Suite", "Unit test bundle", "UI test bundle") else []))


for node in tests.get("testNodes", []):
    walk(node, [])
# Nothing ran: it didn't build.
if passed + len(failed) + skipped == 0:
    compiler_errors()

lines = [f"## Tests: {passed} passed, {len(failed)} failed, {skipped} skipped"]
for name, why in failed:
    lines.append(f"- **{name}**")
    lines.extend(f"  - {each}" for each in why[:8])
summary(lines)
annotate("notice" if not failed else "error", f"Tests: {passed} passed, {len(failed)} failed",
         "\n".join(f"{name}: {' | '.join(why[:4])}" for name, why in failed[:60]) or "all passed")
print("\n".join(lines))
