"""Checks that every SF Symbol the app names exists on a simulator's iOS: a symbol
newer than the iOS the app runs on draws as nothing, and the compiler can't tell.

    check_symbols.py <runtime root> <source folder>...

Reads the symbol names iOS knows from its CoreGlyphs bundle (name_availability.plist,
and name_aliases.strings for old names), and the macOS host's for the full list.
Any string literal in the sources that the host knows as a symbol but the runtime
doesn't is reported (exit 1)."""
import pathlib
import plistlib
import re
import sys

LITERAL = re.compile(r'"([a-z0-9]+(?:\.[a-z0-9]+)+)"')


def known_symbols(root):
    names = set()
    for bundle in pathlib.Path(root).glob("System/Library/CoreServices/CoreGlyphs.bundle"):
        for plist in bundle.rglob("name_availability.plist"):
            with plist.open("rb") as f:
                names |= set(plistlib.load(f).get("symbols", {}))
        for aliases in bundle.rglob("name_aliases.strings"):
            with aliases.open("rb") as f:
                data = f.read()
            try:
                names |= set(plistlib.loads(data))
            except Exception:
                names |= set(re.findall(r'"([^"]+)"\s*=', data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", "ignore")))
    return names


runtime_root, sources = sys.argv[1], sys.argv[2:]
on_runtime = known_symbols(runtime_root)
on_host = known_symbols("/")
if not on_runtime or not on_host:
    print(f"::warning title=SF Symbols::Couldn't read the symbol lists (runtime {len(on_runtime)}, host {len(on_host)})")
    sys.exit(0)

used = {}
for folder in sources:
    for path in sorted(pathlib.Path(folder).rglob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            for name in LITERAL.findall(line):
                used.setdefault(name, f"{path}:{number}")

symbols = {name: where for name, where in used.items() if name in on_host or name in on_runtime}
missing = {name: where for name, where in symbols.items() if name not in on_runtime}
print(f"{len(symbols)} SF Symbols named in the app; {len(missing)} missing on this iOS")
for name, where in sorted(missing.items()):
    print(f"::error file={where.split(':')[0]},line={where.split(':')[1]},title=SF Symbol missing::{name} doesn't exist on this iOS")
sys.exit(1 if missing else 0)
