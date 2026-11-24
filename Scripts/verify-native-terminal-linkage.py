#!/usr/bin/env python3
"""Read-only evidence from an actual Santty build, not source-level certification.

Checks each Mach-O architecture (including Debug's companion dylib), actual
link commands and resolved package state. Does not build, launch or modify apps.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess

REQUIRED = {"_ghostty_terminal_new", "_ghostty_terminal_vt_write", "_ghostty_terminal_paste"}
RETIRED_PACKAGES = {"libghostty-spm", "ghosttykit", "ghosttyterminal", "ghosttytheme", "displaylink"}
LEGACY = re.compile(r"_ghostty_(?:app_|surface_|config_)|\$s(?:15GhosttyTerminal|12GhosttyTheme)")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def verify(app, log, state):
    executable = app / "Contents/MacOS/Santty"
    images = [executable]
    debug = executable.with_name("Santty.debug.dylib")
    if debug.exists():
        images.append(debug)
    issues, architectures = [], {}
    for arch in run("xcrun", "lipo", "-archs", str(executable)).split():
        symbols = set()
        for image in images:
            output = run("xcrun", "nm", "-arch", arch, "-U", str(image))
            symbols.update(line.split()[-1] for line in output.splitlines() if line.split())
            libraries = run("xcrun", "otool", "-arch", arch, "-L", str(image))
            if re.search(r"GhosttyKit|GhosttyTerminal|GhosttyTheme|libghostty-spm", libraries):
                issues.append(f"Retired dynamic dependency in {image} ({arch})")
        missing = REQUIRED - symbols
        legacy = sorted(s for s in symbols if LEGACY.search(s))
        if missing:
            issues.append(f"Missing VT definitions ({arch}): {sorted(missing)}")
        if legacy:
            issues.append(f"Retired definitions ({arch}): {legacy}")
        demangled = subprocess.run(["xcrun","swift-demangle"],input="\n".join(sorted(symbols)),
                                   check=True,capture_output=True,text=True).stdout
        if "SwiftTerm.TerminalRenderView" not in demangled:
            issues.append(f"Missing SwiftTerm renderer definitions ({arch})")
        architectures[arch] = {"vtDefinitions": sorted(REQUIRED & symbols), "retiredDefinitions": legacy}
    source = "\n".join(path.read_text() for path in log)
    links = []
    for line in source.splitlines():
        if " -o " not in line or "/clang " not in line:
            continue
        args = shlex.split(line.strip())
        if "-o" not in args:
            continue
        destination = Path(args[args.index("-o") + 1])
        if destination.name in {"Santty", "Santty.debug.dylib"}:
            links.append(args)
    # Debug's tiny launcher stub deliberately has no VT. SwiftPM contributes
    # renderer objects via filelist/autolink, not a direct -lSwiftTerm flag;
    # verify its actual renderer definitions above rather than assuming a flag.
    name = "Santty.debug.dylib" if debug.exists() else "Santty"
    vt_links = [args for args in links if Path(args[args.index("-o")+1]).name == name]
    if not vt_links or any("-lghostty-vt" not in args for args in vt_links):
        issues.append("No complete production VT link command for every recorded implementation link")
    for args in links:
        if any(re.search(r"GhosttyKit|GhosttyTerminal|GhosttyTheme|libghostty-spm", arg) for arg in args):
            issues.append("Retired input in a production app link command")
    resolved = json.loads(state.read_text())["object"]
    packages = sorted({item["packageRef"]["identity"].lower() for item in resolved["dependencies"]})
    if retired := RETIRED_PACKAGES.intersection(packages):
        issues.append(f"Retired resolved packages (use a fresh private build directory): {sorted(retired)}")
    if "ghostty-vt.xcframework" not in source or "SwiftTerm" not in source:
        issues.append("Missing original VT archive / SwiftTerm build provenance")
    return {"ok": not issues, "app": str(app), "buildLogs": [str(path) for path in log], "architectures": architectures,
            "productionLinkCommands": len(links), "vtImplementationLinkCommands": len(vt_links), "resolvedPackages": packages, "issues": issues,
            "scope": "Resolved/link/Mach-O evidence only; not GUI, system-input, protocol parity or energy certification."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--build-log", required=True, type=Path, action="append",
                        help="Repeat for clean provenance plus subsequent incremental link logs")
    parser.add_argument("--workspace-state", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = verify(args.app, args.build_log, args.workspace_state)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report = {"ok": False, "issues": [str(error)]}
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
