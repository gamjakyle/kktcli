"""Contract tests for install.sh and `make dist`.

install.sh runs with test doubles for curl, uname and swift first on PATH and with HOME and
TMPDIR inside a temporary directory, so these tests use no network, build nothing and write
nothing outside that directory.
"""

import hashlib
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SH = REPO_ROOT / "install.sh"
MAKEFILE = REPO_ROOT / "Makefile"
SOURCES = REPO_ROOT / "Sources"
RELEASES = "https://github.com/gamjakyle/kktcli/releases/download"
CLONE = "git clone https://github.com/gamjakyle/kktcli.git"
# `curl ... | bash` on a stock Mac runs this bash (3.2).
BASH = "/bin/bash"

FAKE_CURL = """#!/bin/sh
# curl double: serves release assets from $FAKE_RELEASE_DIR by file name, logs every URL.
out=
url=
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
printf '%s\\n' "$url" >> "$FAKE_LOG_DIR/curl"
asset="$FAKE_RELEASE_DIR/${url##*/}"
if [ -z "$out" ] || [ ! -f "$asset" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cp "$asset" "$out"
"""

FAKE_UNAME = """#!/bin/sh
if [ "${1:-}" = -m ]; then echo "${FAKE_UNAME_M:-arm64}"; else echo Darwin; fi
"""

FAKE_SWIFT = """#!/bin/sh
# swift double: `swift build` puts the kktcli double into the checkout, logs its arguments.
printf '%s\\n' "$*" >> "$FAKE_LOG_DIR/swift"
bin_dir="$PWD/.fake-build/release"
case " $* " in
  *" --show-bin-path "*) echo "$bin_dir"; exit 0 ;;
esac
mkdir -p "$bin_dir" && cp "$FAKE_KKTCLI" "$bin_dir/kktcli" && chmod 755 "$bin_dir/kktcli"
"""

FAKE_KKTCLI = """#!/bin/sh
# kktcli double: logs its arguments and prints a version line.
printf '%s\\n' "$*" >> "$FAKE_LOG_DIR/kktcli"
echo "$FAKE_KKTCLI_VERSION (test double)"
"""


def write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def tarball_name(version: str) -> str:
    return f"kktcli-{version}-macos-arm64.tar.gz"


class Sandbox:
    """A temporary HOME, TMPDIR, fake release server and test doubles for one test."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.home = root / "home"
        self.tmp = root / "tmp"
        self.fakebin = root / "fakebin"
        self.release = root / "release"
        self.logs = root / "logs"
        for directory in (self.home, self.tmp, self.fakebin, self.release, self.logs):
            directory.mkdir()
        write_executable(self.fakebin / "curl", FAKE_CURL)
        write_executable(self.fakebin / "uname", FAKE_UNAME)
        write_executable(self.fakebin / "swift", FAKE_SWIFT)
        self.kktcli_double = root / "kktcli-double"
        write_executable(self.kktcli_double, FAKE_KKTCLI)

    def env(self, extra: dict[str, str]) -> dict[str, str]:
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "TMPDIR": str(self.tmp),
            "LANG": "C",
            "FAKE_LOG_DIR": str(self.logs),
            "FAKE_RELEASE_DIR": str(self.release),
            "FAKE_KKTCLI": str(self.kktcli_double),
            "FAKE_KKTCLI_VERSION": "9.8.7",
        }
        env.update(extra)
        return env

    def publish(self, version: str, checksum_text: str | None = None) -> str:
        """Puts a release tarball (kktcli double, mode 0644) and its .sha256 on the fake server."""
        name = tarball_name(version)
        tarball = self.release / name

        def readable_only(info: tarfile.TarInfo) -> tarfile.TarInfo:
            info.mode = 0o644
            return info

        with tarfile.open(tarball, "w:gz") as archive:
            archive.add(self.kktcli_double, arcname="kktcli", filter=readable_only)
            archive.add(REPO_ROOT / "LICENSE", arcname="LICENSE")
        if checksum_text is None:
            checksum_text = f"{hashlib.sha256(tarball.read_bytes()).hexdigest()}  {name}\n"
        (self.release / f"{name}.sha256").write_text(checksum_text, encoding="utf-8")
        return name

    def make_checkout(self, version: str) -> Path:
        """A minimal kktcli checkout holding a copy of install.sh."""
        checkout = self.root / "checkout"
        (checkout / "Sources" / "kktcli").mkdir(parents=True)
        (checkout / "Package.swift").write_text('let package = Package(name: "kktcli")\n', encoding="utf-8")
        (checkout / "VERSION").write_text(f"{version}\n", encoding="utf-8")
        shutil.copy(INSTALL_SH, checkout / "install.sh")
        return checkout

    def run_piped(self, *args: str, cwd: Path | None = None, **env: str) -> subprocess.CompletedProcess[str]:
        """Like `curl ... | bash -s -- ARGS`: the script arrives on stdin."""
        return subprocess.run(
            [BASH, "-s", "--", *args],
            input=INSTALL_SH.read_text(encoding="utf-8"),
            cwd=cwd or self.root,
            env=self.env(env),
            capture_output=True,
            text=True,
            timeout=60,
        )

    def run_file(self, script: Path, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH, str(script), *args],
            cwd=self.root,
            env=self.env(env),
            capture_output=True,
            text=True,
            timeout=60,
        )

    def log(self, tool: str) -> list[str]:
        path = self.logs / tool
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def home_files(self) -> list[str]:
        return sorted(path.relative_to(self.home).as_posix() for path in self.home.rglob("*"))


def output(result: subprocess.CompletedProcess[str]) -> str:
    return f"exit {result.returncode}\n--- stdout\n{result.stdout}\n--- stderr\n{result.stderr}"


class InstallScriptSourceTests(unittest.TestCase):
    def test_is_valid_bash(self) -> None:
        result = subprocess.run([BASH, "-n", str(INSTALL_SH)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_strict_mode_without_privilege_escalation_or_kmsg_data(self) -> None:
        script = INSTALL_SH.read_text(encoding="utf-8")
        self.assertIn("set -eu", script)
        self.assertNotIn("sudo", script.lower())
        self.assertNotIn(".kmsg", script)

    def test_downloads_with_curl_verifies_with_shasum_and_can_build(self) -> None:
        script = INSTALL_SH.read_text(encoding="utf-8")
        for text in (
            "curl -fsSL",
            "shasum -a 256 -c",
            "/releases/download/v$version",
            "swift build",
            '"$HOME/.local/bin"',
        ):
            self.assertIn(text, script)


class InstallScriptDownloadTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self._tmp.name))
        self.dest = self.box.home / ".local" / "bin" / "kktcli"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_piped_install_verifies_the_download_and_installs_into_home_local_bin(self) -> None:
        name = self.box.publish("9.8.7")

        result = self.box.run_piped("--version", "9.8.7")

        self.assertEqual(result.returncode, 0, output(result))
        url = f"{RELEASES}/v9.8.7/{name}"
        self.assertEqual(self.box.log("curl"), [url, f"{url}.sha256"])
        self.assertIn(f"{name}: OK", result.stdout)
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o755)
        self.assertEqual(self.box.log("kktcli"), ["--version"])
        for text in (
            "System Settings > Privacy & Security > Accessibility",
            f"enter {self.dest}, add it and turn it on",
            "After every update or rebuild, remove the kktcli entry there and add it again",
            "kktcli status",
            f"{self.dest.parent} is not on your PATH",
        ):
            self.assertIn(text, result.stdout)
        # Only the install directory was written, and the temporary directory is gone.
        self.assertEqual(self.box.home_files(), [".local", ".local/bin", ".local/bin/kktcli"])
        self.assertEqual(list(self.box.tmp.iterdir()), [])

    def test_checksum_mismatch_installs_nothing(self) -> None:
        name = tarball_name("9.8.7")
        self.box.publish("9.8.7", checksum_text=f"{'0' * 64}  {name}\n")

        result = self.box.run_piped("--version", "9.8.7")

        self.assertNotEqual(result.returncode, 0, output(result))
        self.assertIn(f"SHA-256 mismatch for {name}; nothing was installed", result.stderr)
        self.assertEqual(self.box.home_files(), [])
        self.assertEqual(self.box.log("kktcli"), [])
        self.assertEqual(self.box.log("swift"), [])
        self.assertEqual(list(self.box.tmp.iterdir()), [])

    def test_checksum_file_must_name_this_tarball_once(self) -> None:
        name = tarball_name("9.8.7")
        for label, text in (
            ("empty", ""),
            ("another file", f"{'0' * 64}  other.tar.gz\n"),
            ("two lines", f"{'0' * 64}  {name}\n{'1' * 64}  {name}\n"),
        ):
            with self.subTest(label):
                self.box.publish("9.8.7", checksum_text=text)
                result = self.box.run_piped("--version", "9.8.7")
                self.assertNotEqual(result.returncode, 0, output(result))
                self.assertIn("nothing was installed", result.stderr)
                self.assertEqual(self.box.home_files(), [])

    def test_dry_run_downloads_and_writes_nothing(self) -> None:
        name = self.box.publish("9.8.7")

        result = self.box.run_piped("--version", "9.8.7", "--dry-run")

        self.assertEqual(result.returncode, 0, output(result))
        self.assertIn(f"Would download {RELEASES}/v9.8.7/{name}", result.stdout)
        self.assertIn(f"Would create {self.dest.parent}", result.stdout)
        self.assertIn("Privacy & Security > Accessibility", result.stdout)
        self.assertEqual(self.box.log("curl"), [])
        self.assertEqual(self.box.home_files(), [])
        self.assertEqual(list(self.box.tmp.iterdir()), [])

    def test_version_comes_from_the_option_then_the_environment_then_the_checkout(self) -> None:
        script = self.box.make_checkout("4.5.6") / "install.sh"
        for label, result, version in (
            ("--version", self.box.run_file(script, "--dry-run", "--version", "1.2.3", KKTCLI_VERSION="2.3.4"), "1.2.3"),
            ("KKTCLI_VERSION", self.box.run_file(script, "--dry-run", KKTCLI_VERSION="2.3.4"), "2.3.4"),
            ("checkout VERSION", self.box.run_file(script, "--dry-run"), "4.5.6"),
        ):
            with self.subTest(label):
                self.assertEqual(result.returncode, 0, output(result))
                self.assertIn(f"{RELEASES}/v{version}/{tarball_name(version)}", result.stdout)

    def test_stops_before_downloading_without_a_valid_version(self) -> None:
        # Piped, the script has no VERSION file next to it, even when run inside a checkout.
        checkout = self.box.make_checkout("4.5.6")
        for cwd in (self.box.root, checkout):
            with self.subTest(cwd=cwd.name):
                missing = self.box.run_piped(cwd=cwd)
                self.assertNotEqual(missing.returncode, 0, output(missing))
                self.assertIn("no version to install: pass --version X.Y.Z", missing.stderr)
        for version in ("v0.2.0", "0.2", "0.2.0-beta", "01.2.0", "0.2.0/../x"):
            with self.subTest(version=version):
                result = self.box.run_piped("--version", version)
                self.assertNotEqual(result.returncode, 0, output(result))
                self.assertIn("is not a release version", result.stderr)
        self.assertEqual(self.box.log("curl"), [])
        self.assertEqual(self.box.home_files(), [])


class InstallScriptSourceBuildTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.box = Sandbox(Path(self._tmp.name))
        self.prefix = self.box.root / "prefix"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_failed_download_in_a_checkout_falls_back_to_a_source_build(self) -> None:
        script = self.box.make_checkout("4.5.6") / "install.sh"

        # Nothing is published, so the download fails.
        result = self.box.run_file(script, "--prefix", str(self.prefix), FAKE_KKTCLI_VERSION="4.5.6")

        self.assertEqual(result.returncode, 0, output(result))
        self.assertEqual(self.box.log("curl"), [f"{RELEASES}/v4.5.6/{tarball_name('4.5.6')}"])
        self.assertEqual(self.box.log("swift"), ["build -c release", "build -c release --show-bin-path"])
        self.assertEqual(stat.S_IMODE((self.prefix / "kktcli").stat().st_mode), 0o755)
        self.assertEqual(self.box.log("kktcli"), ["--version"])
        self.assertIn("Privacy & Security > Accessibility", result.stdout)

    def test_from_source_and_other_cpus_build_the_checkout_without_downloading(self) -> None:
        script = self.box.make_checkout("4.5.6") / "install.sh"
        for label, args, env in (
            ("--from-source", ("--from-source",), {}),
            ("x86_64", (), {"FAKE_UNAME_M": "x86_64"}),
        ):
            with self.subTest(label):
                (self.box.logs / "swift").unlink(missing_ok=True)
                result = self.box.run_file(
                    script,
                    *args,
                    "--prefix",
                    str(self.prefix),
                    FAKE_KKTCLI_VERSION="4.5.6",
                    KKTCLI_BUILD_PATH=".build-dist",
                    KKTCLI_BUILD_JOBS="2",
                    **env,
                )
                self.assertEqual(result.returncode, 0, output(result))
                self.assertEqual(self.box.log("swift")[0], "build -c release --build-path .build-dist -j 2")
                self.assertTrue((self.prefix / "kktcli").is_file())
        self.assertEqual(self.box.log("curl"), [])

    def test_outside_a_checkout_it_explains_how_to_build_from_source(self) -> None:
        for label, args, env in (
            ("--from-source", ("--from-source",), {}),
            ("x86_64", ("--version", "9.8.7"), {"FAKE_UNAME_M": "x86_64"}),
            ("download fails", ("--version", "9.8.7"), {}),
        ):
            with self.subTest(label):
                result = self.box.run_piped(*args, **env)
                self.assertNotEqual(result.returncode, 0, output(result))
                self.assertIn(CLONE, result.stdout)
                self.assertIn("./install.sh --from-source", result.stdout)
                self.assertEqual(self.box.log("swift"), [])
                self.assertEqual(self.box.home_files(), [])
                self.assertEqual(list(self.box.tmp.iterdir()), [])


class MakeDistContractTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("make"), "make is not installed")
    def test_dist_target_packages_the_release_tarball_and_its_checksum(self) -> None:
        self.assertRegex(MAKEFILE.read_text(encoding="utf-8"), r"(?m)^dist:")
        version = (REPO_ROOT / "VERSION").read_text(encoding="utf-8").strip()
        name = tarball_name(version)

        # -n prints the recipe without running it.
        result = subprocess.run(["make", "-n", "dist"], cwd=REPO_ROOT, capture_output=True, text=True, timeout=60)

        self.assertEqual(result.returncode, 0, result.stderr)
        plan = result.stdout
        self.assertIn('if [ "$(uname -m)" != "arm64" ]', plan)
        self.assertIn("swift build -c release", plan)
        self.assertIn(f'tar -czf "dist/{name}"', plan)
        self.assertIn("kktcli LICENSE README.en.md", plan)
        # Bare file name, written inside dist/, so `shasum -a 256 -c` works there.
        self.assertIn(f'cd dist && shasum -a 256 "{name}" > "{name}.sha256"', plan)


class InstallDocsAndSourcesTests(unittest.TestCase):
    def test_no_swift_source_has_network_code(self) -> None:
        for path in sorted(SOURCES.rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(REPO_ROOT).as_posix()):
                self.assertNotIn("URLSession", source)
                self.assertNotRegex(source, r"\bcurl\b")

    def test_readmes_show_the_install_command(self) -> None:
        command = "curl -fsSL https://raw.githubusercontent.com/gamjakyle/kktcli/main/install.sh | bash -s -- --version "
        for readme in ("README.md", "README.en.md"):
            with self.subTest(readme=readme):
                text = (REPO_ROOT / readme).read_text(encoding="utf-8")
                self.assertIn(command, text)
                self.assertIn("./install.sh --from-source", text)
                self.assertIn("kktcli status", text)


if __name__ == "__main__":
    unittest.main()
