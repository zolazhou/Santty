import importlib.util
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / "audit-terminal-dependencies.py"
SPEC = importlib.util.spec_from_file_location("terminal_dependency_audit", MODULE)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class TerminalDependencyAuditTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="santty-audit-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def put(self, path, content):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)
        return destination

    def report(self, **kwargs):
        return AUDIT.audit(self.root, expected=kwargs.pop("expected", {}),
                           build=kwargs.pop("build", {}), retire=kwargs.pop("retire", ()), **kwargs)

    def testExactModulesAttributesScopedImportsAndNewVTExclusion(self):
        rows = AUDIT.imports_in("\n".join([
            "// import GhosttyTerminal", "import GhosttyVt", "import GhosttyTerminalExtra",
            "@testable import GhosttyTerminal", "@preconcurrency import GhosttyTheme",
            "public import struct GhosttyKit.SomeType", "@_spi(Internal) import libghostty",
        ]))
        self.assertEqual([row["module"] for row in rows], ["GhosttyTerminal", "GhosttyTheme", "GhosttyKit", "libghostty"])
        self.assertEqual([row["line"] for row in rows], [4, 5, 6, 7])

    def testReviewedImportsMatchWithoutTouchingFiles(self):
        path = "Santty/Sources/Pane.swift"
        file = self.put(path, "import GhosttyTerminal\n")
        before = file.read_bytes(), file.stat().st_mtime_ns
        report = self.report(expected={path: {"GhosttyTerminal"}})
        self.assertTrue(report["ok"])
        self.assertEqual(report["importStatements"], 1)
        self.assertEqual(report["productionFiles"], 1)
        self.assertEqual(before, (file.read_bytes(), file.stat().st_mtime_ns))

    def testUnexpectedOldImportInTerminalTestsIsNotIgnored(self):
        self.put("Santty/TerminalTests/Leak.swift", "import GhosttyTheme")
        report = self.report()
        self.assertFalse(report["ok"])
        self.assertIn("Leak.swift", report["issues"][0])
        self.assertEqual(report["testFiles"], 1)

    def testRemovedOrChangedExpectedImportRequiresInventoryReview(self):
        self.assertFalse(self.report(expected={"Santty/Sources/Missing.swift": {"GhosttyTerminal"}})["ok"])
        self.put("Santty/Sources/Missing.swift", "import GhosttyKit")
        self.assertFalse(self.report(expected={"Santty/Sources/Missing.swift": {"GhosttyTerminal"}})["ok"])

    def testBuildEdgesAreCheckedEvenWithNoDirectImports(self):
        edge = '.package(product: "GhosttyTheme")'
        self.put("Project.swift", edge)
        self.assertTrue(self.report(build={"Project.swift": (edge,)})["ok"])
        self.assertFalse(self.report(require_removed=True, build={"Project.swift": (edge,)})["ok"])

    def testRemovalModeRejectsImportsAndObsoleteArtifacts(self):
        self.put("Santty/Tests/Legacy.swift", "@testable import GhosttyTerminal")
        self.put("Patches/Old.patch", "old patch")
        report = self.report(require_removed=True, retire=("Patches/Old.patch",))
        self.assertFalse(report["ok"])
        self.assertEqual(len(report["issues"]), 2)
        self.assertEqual(report["testFiles"], 1)

    def testRemovalModeAllowsNewVTAndAbsentLegacyFiles(self):
        self.put("Santty/Sources/Native.swift", "import GhosttyVt\nimport SwiftTerm")
        self.assertTrue(self.report(require_removed=True, build={"Project.swift": ("GhosttyTerminal",)}, retire=("Patches/Old.patch",))["ok"])

    def testRemovalModeRejectsRetiredLabDirectoryAndBuildEdges(self):
        self.put("Experiments/NativeTerminalLab/obsolete.txt", "retired")
        self.put("Project.swift", 'let target = "SanttyTerminalLab"')
        self.put("mise.toml", '[tasks."terminal-lab:generate"]')
        report = self.report(require_removed=True,
            build={"Project.swift": ("SanttyTerminalLab",),
                   "mise.toml": ('[tasks."terminal-lab:generate"]',)},
            retire=("Experiments/NativeTerminalLab",))
        self.assertFalse(report["ok"])
        self.assertEqual(len(report["issues"]), 3)

    def testRemovalModeAllowsFormalTerminalTestTarget(self):
        self.put("Project.swift", 'name: "SanttyTerminalTests"')
        self.put("Santty/TerminalTests/Native.swift", "@testable import Santty\\nimport GhosttyVt")
        self.assertTrue(self.report(require_removed=True,
            build={"Project.swift": ("SanttyTerminalLab",)},
            retire=("Experiments/NativeTerminalLab",))["ok"])

    def testRepositoryEscapeIsRefused(self):
        with tempfile.TemporaryDirectory(prefix="santty-audit-outside-") as outside:
            file = Path(outside) / "outside.swift"
            file.write_text("import GhosttyTerminal")
            link = self.root / "Santty/Sources/Linked.swift"
            link.parent.mkdir(parents=True)
            link.symlink_to(file)
            with self.assertRaisesRegex(ValueError, "outside repository"):
                self.report()


if __name__ == "__main__":
    unittest.main()
