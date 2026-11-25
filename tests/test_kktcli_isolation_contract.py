import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
PACKAGE = REPO_ROOT / "Package.swift"


def swift_sources() -> str:
    return "\n".join(path.read_text(encoding="utf-8") for path in sorted(SOURCES.rglob("*.swift")))


class KktcliIsolationContractTests(unittest.TestCase):
    """kktcli must not touch the data of an installed kmsg and must not use the network."""

    def test_executable_and_targets_are_named_kktcli(self) -> None:
        package = PACKAGE.read_text(encoding="utf-8")
        self.assertIn('name: "kktcli"', package)
        self.assertTrue((SOURCES / "kktcli" / "kktcli.swift").exists())
        self.assertNotIn('name: "kmsg"', package)

    def test_state_lives_in_kktcli_directories(self) -> None:
        source = swift_sources()
        # ~/.kktcli for the chat registry and AX path cache.
        self.assertEqual(source.count('.appendingPathComponent(".kktcli", isDirectory: true)'), 2)
        # ~/.config/kktcli for credentials.
        self.assertIn('.appendingPathComponent("kktcli", isDirectory: true)', source)
        for forbidden in ('".kmsg"', 'appendingPathComponent("kmsg"', "KMSG_"):
            self.assertNotIn(forbidden, source, forbidden)

    def test_no_network_code(self) -> None:
        source = swift_sources()
        for api in (
            "URLSession",
            "URLRequest",
            "import Network",
            "NWConnection",
            "NWListener",
            "CFSocket",
            "CFStreamCreatePairWithSocket",
            "getaddrinfo",
            "Socket(",
        ):
            self.assertNotIn(api, source, api)
        # The only URL literal is the local System Settings pane for Accessibility permission.
        url_literals = re.findall(r'URL\(string:\s*"([^"]+)"', source)
        self.assertEqual(url_literals, ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])

    def test_no_self_update_or_release_automation(self) -> None:
        self.assertFalse((SOURCES / "kktcli" / "Update").exists())
        self.assertFalse((SOURCES / "kktcli" / "Commands" / "UpdateCommand.swift").exists())
        self.assertFalse((REPO_ROOT / ".github" / "workflows" / "release.yml").exists())
        self.assertNotIn("UpdateCommand", swift_sources())


if __name__ == "__main__":
    unittest.main()
