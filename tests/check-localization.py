#!/usr/bin/env python3
"""Fail if the String Catalog is missing a translation.

Usage:
  python3 tests/check-localization.py                 # catalog completeness only
  python3 tests/check-localization.py --extracted DIR # also compare against the
      compiler-extracted keys (*.stringsdata under DIR, e.g. the app target's
      DerivedData Objects-normal/arm64 folder) so a new Text("...") /
      LocalizedStringResource literal that nobody added to the catalog is
      caught too. (Dynamic keys such as drum-loop names are looked up by
      value and are not extractable; they live in the catalog by hand.)

Checks, for every key in LiminalGenerator/Resources/Localizable.xcstrings
whose entry does not set "shouldTranslate": false:
  * every language in LANGS has a translation in state "translated" with a
    non-empty value (plural/device variations are walked recursively);
  * the printf-style specifiers (%lld, %@, %%, ...) match the English key's.
Exit status 0 = OK, 1 = problems found.
"""
import json, re, sys, glob, os

LANGS = ["es", "pt-BR", "fr", "de", "ja"]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "LiminalGenerator/Resources/Localizable.xcstrings")
SPEC = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:l|ll|h|hh|z|q)?[@dDiuUxXoOfeEgGcCsSp]|%%")


def units(loc):
    """Yield every stringUnit under a localization (handles variations)."""
    if "stringUnit" in loc:
        yield loc["stringUnit"]
    for group in loc.get("variations", {}).values():
        for sub in group.values():
            yield from units(sub)


def specs(s):
    return sorted(SPEC.findall(s))


def main():
    errors = []
    with open(CATALOG, encoding="utf-8") as f:
        cat = json.load(f)
    if cat.get("sourceLanguage") != "en":
        errors.append("sourceLanguage must be en")
    checked = skipped = 0
    for key, entry in cat["strings"].items():
        if entry.get("shouldTranslate") is False:
            skipped += 1
            continue
        checked += 1
        for lang in LANGS:
            loc = entry.get("localizations", {}).get(lang)
            if not loc:
                errors.append(f"{lang}: missing translation for {key!r}")
                continue
            us = list(units(loc))
            if not us:
                errors.append(f"{lang}: no string unit for {key!r}")
            for u in us:
                if u.get("state") != "translated" or not u.get("value", "").strip():
                    errors.append(f"{lang}: {key!r} is not translated (state={u.get('state')!r})")
                elif specs(u["value"]) != specs(key):
                    errors.append(f"{lang}: format specifiers differ for {key!r}: {specs(key)} vs {specs(u['value'])}")

    if "--extracted" in sys.argv:
        d = sys.argv[sys.argv.index("--extracted") + 1]
        found = set()
        for p in glob.glob(os.path.join(d, "*.stringsdata")):
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
            for item in data.get("tables", {}).get("Localizable", []):
                found.add(item["key"])
        for key in sorted(found - set(cat["strings"])):
            errors.append(f"extracted from code but not in catalog: {key!r}")

    for e in errors:
        print("FAIL:", e)
    print(f"{checked} translatable keys x {len(LANGS)} languages checked, {skipped} English-only keys skipped, {len(errors)} problem(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
