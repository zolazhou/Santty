#!/usr/bin/env python3
"""Strict offline extraction of pinned pure theme DATA, not Ghostty config parsing.

Input is the prepared source tree of libghostty-spm at the recorded revision.
No downloads, runtime old-module dependency, or user configuration reads.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

REVISION = "1d84cf66fe29abd1f24f10b88dcfc25882cf68ee"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Santty/Resources/TerminalThemes.json"
STRING = r'"(?:[^"\\]|\\.)*"'
FIELDS = {"name", "background", "foreground", "cursorColor", "cursorText", "selectionBackground", "selectionForeground", "palette"}


def extract(package):
    if (package / ".santty-revision").read_text().strip() != REVISION:
        raise ValueError("Unexpected source revision; review extraction before changing pin")
    source = package / "Sources/GhosttyTheme"
    definitions, hashes = {}, {}
    for file in sorted((source / "Themes").glob("Themes_*.swift")):
        text = file.read_text()
        hashes[file.name] = hashlib.sha256(file.read_bytes()).hexdigest()
        matches = list(re.finditer(r"static let (\w+) = GhosttyThemeDefinition\(\s*(.*?)\s*^    \)", text, re.S | re.M))
        if len(matches) != text.count("= GhosttyThemeDefinition("):
            raise ValueError(f"Unrecognized initializer in {file.name}")
        for match in matches:
            symbol, body = match.groups()
            fields, offset = {}, 0
            pattern = re.compile(rf"\s*(\w+):\s*({STRING}|\[[^\]]*\])\s*,?", re.S)
            while offset < len(body):
                field = pattern.match(body, offset)
                if not field:
                    raise ValueError(f"Unparsed source in {symbol}: {body[offset:offset + 50]!r}")
                key, literal = field.groups()
                if key not in FIELDS or key in fields:
                    raise ValueError(f"Unexpected/duplicate {key} in {symbol}")
                if key == "palette":
                    palette, rest = {}, literal[1:-1]
                    while rest.strip():
                        entry = re.match(rf"\s*(\d+):\s*({STRING})\s*,?", rest)
                        if not entry:
                            raise ValueError(f"Invalid palette in {symbol}")
                        index, color = entry.groups()
                        if index in palette or not 0 <= int(index) <= 255:
                            raise ValueError(f"Invalid/duplicate palette index in {symbol}")
                        palette[index] = json.loads(color)
                        rest = rest[entry.end():]
                    fields[key] = palette
                else:
                    fields[key] = json.loads(literal)
                offset = field.end()
            if symbol in definitions or not {"name", "background", "foreground"} <= fields.keys():
                raise ValueError(f"Invalid definition {symbol}")
            for key, value in fields.items():
                colors = value.values() if key == "palette" else ([] if key == "name" else [value])
                if any(not re.fullmatch(r"#?[0-9a-fA-F]{6}", color) for color in colors):
                    raise ValueError(f"Non-RGB6 source color in {symbol}.{key}")
            definitions[symbol] = fields
    catalog = (source / "Themes/ThemeCatalog_Generated.swift").read_text()
    symbols = re.findall(r"^\s*\.(\w+),\s*$", catalog, re.M)
    if not symbols or len(set(symbols)) != len(symbols) or set(symbols) != definitions.keys():
        raise ValueError("Catalog must reference exactly every definition once")
    themes = [definitions[symbol] for symbol in symbols]
    if len({theme["name"] for theme in themes}) != len(themes):
        raise ValueError("Duplicate theme name")
    hashes["ThemeCatalog_Generated.swift"] = hashlib.sha256(catalog.encode()).hexdigest()
    return {"schemaVersion": 1, "sourceRevision": REVISION, "sourceSHA256": hashes, "themes": themes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=ROOT / "Vendor/libghostty-spm")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = extract(args.source)
    encoded = (json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()
    if args.check:
        if OUTPUT.read_bytes() != encoded:
            raise SystemExit("Theme artifact drift; regenerate and review")
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        OUTPUT.write_bytes(encoded)
    print(f"{'Checked' if args.check else 'Generated'} {len(result['themes'])} exact-name RGB theme records")


if __name__ == "__main__":
    main()
