import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = REPO_ROOT / "Sources"
SEND_COMMAND = SOURCES / "kktcli" / "Commands" / "SendCommand.swift"
SEND_IMAGE = SOURCES / "kktcli" / "Commands" / "SendImageCommand.swift"
SENDER = SOURCES / "kktcli" / "Send" / "MessageSender.swift"
DIALOG = SOURCES / "kktcli" / "Send" / "SendConfirmationDialog.swift"
SESSION = SOURCES / "kktcli" / "Send" / "RoomSession.swift"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class SendCommandContractTests(unittest.TestCase):
    def test_send_opens_rooms_like_read_and_never_types_blindly(self) -> None:
        command = read(SEND_COMMAND) + read(SEND_IMAGE)
        session = read(SESSION)
        self.assertIn("ChatRoomMenuOpener(kakao: kakao, runner: runner, activity: activity)", session)
        self.assertIn("try access.resolve(locator: ChatListLocator(kakao: early, runner: runner), allowOpenCommand: false)", session)
        self.assertIn("earlyAction == .otherDesktop", session)
        self.assertIn("try room.locate(chatID: $0)", command)
        for forbidden in ("ChatWindowResolver(", "typeTextDirect", "typeTextWithVerification", "forcedTyping", "pressEnterKey"):
            self.assertNotIn(forbidden, command)
        self.assertNotIn("kakao.activate()", read(SEND_COMMAND))

    def test_sending_is_off_unless_enabled_and_there_is_no_dialog(self) -> None:
        self.assertFalse(DIALOG.exists())
        for path in (SEND_COMMAND, SEND_IMAGE):
            command = read(path)
            self.assertIn("try ConfigStore.requireSendEnabled()", command)
            self.assertLess(command.index("try ConfigStore.requireSendEnabled()"), command.index("return perform("))
            for gone in ("SendConfirmationDialog", "SendDialogPolicy", "SEND_CANCELLED", "SEND_CONTEXT_CHANGED"):
                self.assertNotIn(gone, command)
        config = read(SOURCES / "kktcli" / "Commands" / "ConfigCommand.swift")
        self.assertIn('code: "SEND_DISABLED"', config)
        self.assertIn("exitCode: KktcliExitStatus.sendDisabled", config)
        self.assertIn('hint: "Only if you want kktcli to send: kktcli config set send on"', config)
        self.assertIn("chmod(fileURL.path, 0o600)", config)
        self.assertIn('ProcessInfo.processInfo.environment["KKTCLI_CONFIG_DIR"]', config)

    def test_sender_presses_only_the_send_button_and_verifies(self) -> None:
        sender = read(SENDER)
        performs = re.findall(r"AXNodeReader\.perform\(([^)]*)\)", sender)
        self.assertEqual(sorted(performs), sorted(["button, kAXPressAction", "opened.window.axElement, kAXRaiseAction"]))
        self.assertIn("SendButtonSafety.isSendButton(role:", sender)
        self.assertIn("SendVerification.bubbleSent(text: text, before: tailBefore, after: now)", sender)
        self.assertIn('"SEND_INPUT_NOT_EMPTY"', sender)
        # The room is checked again right before 전송 is pressed.
        self.assertLess(sender.index("guard session.stillShows(opened),"), sender.index("AXNodeReader.perform(button, kAXPressAction)"))
        self.assertIn("if allowActivate {", sender)
        # The Enter fallback re-activates the previous app.
        self.assertIn("previous.activate(options: [])", sender)

    def test_image_send_restores_the_clipboard(self) -> None:
        image = read(SEND_IMAGE)
        self.assertIn("let saved = Self.save(pasteboard)", image)
        self.assertIn("Self.restore(saved, to: pasteboard)", image)
        self.assertLess(image.index("let saved = Self.save(pasteboard)"), image.index("pasteboard.clearContents()\n        pasteboard.writeObjects([image])"))


if __name__ == "__main__":
    unittest.main()
