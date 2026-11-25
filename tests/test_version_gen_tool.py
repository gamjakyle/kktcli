import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
# SwiftPM build directory that holds the VersionGenTool build-tool binary; override with
# KKTCLI_BUILD_PATH when building elsewhere (e.g. `swift build --build-path .build-next`).
BUILD_PATH = REPO_ROOT / os.environ.get("KKTCLI_BUILD_PATH", ".build")
ENTRYPOINT = REPO_ROOT / "Sources" / "kktcli" / "kktcli.swift"


def version_gen_binary() -> Path:
    for configuration in ("debug", "release"):
        candidate = BUILD_PATH / configuration / "VersionGenTool-tool"
        if candidate.exists():
            return candidate
    return BUILD_PATH / "debug" / "VersionGenTool-tool"


class VersionGenToolTests(unittest.TestCase):
    def run_version_gen(self, version: str) -> tuple[subprocess.CompletedProcess[str], str | None]:
        binary = version_gen_binary()
        self.assertTrue(binary.exists(), f"missing build tool: {binary} (build first)")
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            version_path = tmp / "VERSION"
            output_path = tmp / "GeneratedVersion.swift"
            version_path.write_text(f"{version}\n", encoding="utf-8")

            result = subprocess.run(
                [str(binary), str(version_path), str(output_path)],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
            )

            output_text = output_path.read_text(encoding="utf-8") if output_path.exists() else None
            return result, output_text

    def test_accepts_semantic_version(self) -> None:
        result, output_text = self.run_version_gen("0.1.0")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(output_text)
        self.assertIn('static let current = "0.1.0"', output_text)

    def test_rejects_versions_that_are_not_major_minor_patch(self) -> None:
        for version in ("2026.0422.22", "0.1", "v0.1.0", "0.1.0-beta", "01.1.0"):
            with self.subTest(version=version):
                result, _ = self.run_version_gen(version)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VERSION must be MAJOR.MINOR.PATCH", f"{result.stdout}\n{result.stderr}")

    def test_repository_version_and_upstream_credit(self) -> None:
        self.assertEqual((REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip(), "0.1.0")
        entrypoint = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn('static let base = "kmsg 1.260921.0"', entrypoint)
        self.assertIn('"\\(current) (based on \\(UpstreamVersion.base))"', entrypoint)
        self.assertIn("version: BuildVersion.display", entrypoint)


if __name__ == "__main__":
    unittest.main()
