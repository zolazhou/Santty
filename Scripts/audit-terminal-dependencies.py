#!/usr/bin/env python3
"""Read-only, lexical migration inventory; not a Swift/linker or UX certification.

--check and --require-removed enforce the production no-legacy denylist.
The historical reviewed inventory remains available through audit() for tests.
Neither mode generates projects, downloads dependencies, or operates terminals.
"""
import argparse
import json
from pathlib import Path
import re

SCOPES = (
    "Santty/Sources", "Santty/Shared", "Santty/Tests",
    "Santty/TerminalTests",
)
LEGACY_MODULES = frozenset({"GhosttyTerminal", "GhosttyTheme", "GhosttyKit", "libghostty"})
# Deliberately exact module names: GhosttyVt is the new, retained C API.
IMPORT = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+"
    r"(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?(\w+)\b"
)
EXPECTED_IMPORTS = {
    "Santty/Sources/App/AppDelegate.swift": {"GhosttyTerminal"},
    "Santty/Sources/Herdr/HerdrTerminalSession+Ghostty.swift": {"GhosttyTerminal"},
    "Santty/Sources/Terminal/TerminalDefaults.swift": {"GhosttyTerminal", "GhosttyTheme"},
    "Santty/Sources/Terminal/TerminalLoggingConfiguration.swift": {"GhosttyTerminal"},
    "Santty/Sources/Workspace/Panes/TerminalPaneController.swift": {"GhosttyTerminal"},
    "Santty/Sources/Workspace/Views/TerminalPaneHostView.swift": {"GhosttyTerminal"},
    "Santty/Sources/Workspace/Views/TerminalScrollModeView.swift": {"GhosttyTerminal"},
    "Santty/Sources/Workspace/WorkspaceViewController.swift": {"GhosttyTerminal"},
    "Santty/Tests/AgentSessionTests.swift": {"GhosttyTerminal"},
    "Santty/Tests/CLIPaneTests.swift": {"GhosttyTerminal"},
    "Santty/Tests/CLITests.swift": {"GhosttyTerminal"},
    "Santty/Tests/HerdrWorkspaceSyncTests.swift": {"GhosttyTerminal"},
    "Santty/Tests/HerdrWorkspaceTests.swift": {"GhosttyTerminal"},
    "Santty/Tests/SanttyTests.swift": {"GhosttyTerminal"},
    "Santty/Tests/TerminalPaneInteractionTests.swift": {"GhosttyTerminal"},
}
LEGACY_BUILD_REFERENCES = {
    "Project.swift": ("Vendor/libghostty-spm", '.package(product: "GhosttyTheme")',
                      '.package(product: "GhosttyTerminal")', "Experiments/NativeTerminalLab",
                      "SanttyTerminalLab", "TUIST_SANTTY_NATIVE_TERMINAL_LAB"),
    "mise.toml": ('[tasks."ghostty:prepare"]', "sh Scripts/prepare-ghostty.sh",
                  '[tasks."terminal-lab:generate"]', "TUIST_SANTTY_NATIVE_TERMINAL_LAB"),
}
RETIRE_FILES = (
    "Experiments/NativeTerminalLab",
    "Scripts/prepare-ghostty.sh",
    "Santty/Sources/Herdr/HerdrTerminalSession+Ghostty.swift",
    "Santty/Sources/Workspace/Views/TerminalScrollModeView.swift",
    "Patches/AppTerminalView+Occlusion.patch",
    "Patches/TerminalSurface+ReadText.swift",
    "Patches/TerminalSurface+ScrollMode.swift",
    "Patches/TerminalSurfaceCoordinator+DetachedWakeups.patch",
    "Patches/TerminalSurfaceCoordinator+DisplayLinkLinger.patch",
    "Patches/TerminalSurfaceCoordinator+DrainBeforeFree.patch",
    "Patches/TerminalWakeGrace.patch",
)


def imports_in(source):
    """Lexical only: conditional imports count; comment/string blocks need review."""
    found = []
    for line, text in enumerate(source.splitlines(), 1):
        match = IMPORT.match(text)
        if match and match[1] in LEGACY_MODULES:
            found.append({"line": line, "module": match[1]})
    return found


def inside(root, path):
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root):
        raise ValueError(f"Refusing source outside repository: {path}")
    return resolved


def audit(root, require_removed=False, expected=None, build=None, retire=None):
    root = root.resolve()
    expected = EXPECTED_IMPORTS if expected is None else expected
    build = LEGACY_BUILD_REFERENCES if build is None else build
    retire = RETIRE_FILES if retire is None else retire
    imports, issues, edges = {}, [], []
    for scope in SCOPES:
        directory = inside(root, scope)
        if not directory.exists():
            continue
        for path in sorted(directory.rglob("*.swift")):
            relative = path.relative_to(root).as_posix()
            found = imports_in(inside(root, relative).read_text())
            if found:
                imports[relative] = found
    actual = {path: {row["module"] for row in rows} for path, rows in imports.items()}
    if require_removed:
        issues.extend(f"Legacy import remains: {path}" for path in actual)
    else:
        for path in sorted(actual.keys() | expected.keys()):
            if actual.get(path, set()) != expected.get(path, set()):
                issues.append(f"Import inventory drift: {path}; expected {sorted(expected.get(path, set()))}, got {sorted(actual.get(path, set()))}")
    for path, needles in build.items():
        file = inside(root, path)
        source = file.read_text() if file.exists() else ""
        for needle in needles:
            count = source.count(needle)
            edges.append({"path": path, "reference": needle, "occurrences": count})
            if (require_removed and count) or (not require_removed and not count):
                issues.append(f"Legacy build reference {'remains' if require_removed else 'changed'}: {path}: {needle}")
    if require_removed:
        issues.extend(f"Obsolete legacy artifact remains: {path}" for path in retire if inside(root, path).exists())
    return {"mode": "require-removed" if require_removed else "check-inventory", "ok": not issues,
            "importFiles": len(imports), "importStatements": sum(map(len, imports.values())),
            "productionFiles": sum(path.startswith("Santty/Sources/") for path in imports),
            "testFiles": sum("/Tests/" in path or "/TerminalTests/" in path for path in imports),
            "imports": imports, "buildReferences": edges, "issues": issues,
            "scope": "Lexical source/build inventory only; not resolved linkage, runtime parity or manual acceptance."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--require-removed", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = audit(Path(__file__).resolve().parent.parent, require_removed=True)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(f"{report['mode']}: {'matches' if report['ok'] else 'FAILED'}; "
              f"{report['productionFiles']} production / {report['testFiles']} test files, {report['importStatements']} legacy imports")
        for issue in report["issues"]:
            print(f"- {issue}")
        print(report["scope"])
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
