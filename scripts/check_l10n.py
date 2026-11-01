#!/usr/bin/env python3
"""Fails if any L("...") literal in Sources/ lacks a Simplified Chinese entry in ZhHans.swift.
Usage: check_l10n.py [--list]   (--list prints every key, for writing translations)"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
lit = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
keys = {}
for f in sorted((root / "Sources").rglob("*.swift")):
    if f.name == "ZhHans.swift" or "BarTapTests" in f.parts:
        continue
    for m in lit.finditer(f.read_text(encoding="utf-8")):
        keys.setdefault(m.group(1), f"{f.relative_to(root)}")
table = (root / "Sources/BarTapCore/ZhHans.swift").read_text(encoding="utf-8")
entry = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*,\s*$', re.M)
have = {m.group(1): m.group(2) for m in entry.finditer(table)}
if "--list" in sys.argv:
    for k in keys:
        print(k)
    sys.exit(0)
missing = [k for k in keys if k not in have]
unused = [k for k in have if k not in keys]
# Format specifiers must match between source and translation.
spec = re.compile(r'%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[@dfsu]|%%')
def specs(x):
    # Positional forms (%2$@) are valid reorderings; compare the conversions themselves.
    return sorted(re.sub(r'%\d+\$', '%', m) for m in spec.findall(x))
bad = [k for k in keys if k in have and specs(k) != specs(have[k])]
for k in missing: print(f"missing zh: {k!r}  ({keys[k]})")
for k in bad: print(f"format mismatch: {k!r} -> {have[k]!r}")
for k in unused: print(f"note: unused zh key: {k!r}")
print(f"{len(keys)} strings, {len(missing)} missing, {len(bad)} format mismatches")
sys.exit(1 if missing or bad else 0)
