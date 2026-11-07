"""Checks that every SF Symbol the app names exists on a simulator's iOS: a symbol
newer than the iOS the app runs on draws as nothing, and the compiler can't tell.

    check_symbols.py list <source folder>... > symbols.tsv
    check_symbols.py check <runtime root> symbols.tsv

`list` writes each string literal in the sources that this Mac knows as a symbol
(run it on the newest macOS, which knows them all), with where it's used. `check`
reports (and exits 1 for) those the simulator's iOS doesn't know. The names come
from CoreGlyphs (name_availability.plist, and name_aliases.strings for old names)."""
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
            data = aliases.read_bytes()
            try:
                names |= set(plistlib.loads(data))
            except Exception:
                text = data.decode("utf-16" if data[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", "ignore")
                names |= set(re.findall(r'"([^"]+)"\s*=', text))
    return names


def list_symbols(folders):
    known = known_symbols("/")
    if not known:
        sys.exit("Couldn't read this Mac's symbol list")
    seen = {}
    for folder in folders:
        for path in sorted(pathlib.Path(folder).rglob("*.swift")):
            for number, line in enumerate(path.read_text().splitlines(), 1):
                for name in LITERAL.findall(line):
                    if name in known:
                        seen.setdefault(name, f"{path}:{number}")
    for name, where in sorted(seen.items()):
        print(f"{name}\t{where}")


def check(runtime_root, listing):
    known = known_symbols(runtime_root)
    if not known:
        print(f"::warning title=SF Symbols::Couldn't read the symbol list in {runtime_root}")
        return 0
    used = [line.split("\t") for line in pathlib.Path(listing).read_text().splitlines() if line]
    missing = [(name, where) for name, where in used if name not in known]
    print(f"{len(used)} SF Symbols named in the app; {len(missing)} missing on this iOS")
    for name, where in missing:
        path, line = where.rsplit(":", 1)
        print(f"::error file={path},line={line},title=SF Symbol missing::{name} doesn't exist on this iOS")
    return 1 if missing else 0


if sys.argv[1] == "list":
    list_symbols(sys.argv[2:])
else:
    sys.exit(check(sys.argv[2], sys.argv[3]))
