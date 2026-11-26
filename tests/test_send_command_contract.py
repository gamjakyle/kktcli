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
        self.assertIn("try access.reopen(kakao: early, locator: earlyLocator)", session)
        self.assertIn("try room.locate(chatID: $0)", command)
        for forbidden in ("ChatWindowResolver(", "typeTextDirect", "typeTextWithVerification", "forcedTyping", "pressEnterKey"):
            self.assertNotIn(forbidden, command)
        self.assertNotIn("kakao.activate()", read(SEND_COMMAND))

    def test_every_send_needs_the_dialog(self) -> None:
        command = read(SEND_COMMAND)
        dialog_index = command.index("SendConfirmationDialog(log:")
        self.assertLess(dialog_index, command.index("MessageSender(session: room"))
        self.assertIn("guard outcome == .send else {", command)
        self.assertNotRegex(command, r"--(?:yes|force|no-confirm|skip-dialog)")
        image = read(SEND_IMAGE)
        self.assertLess(image.index("SendConfirmationDialog(log:"), image.index("ImagePaster(session: room)"))

    def test_dialog_rules(self) -> None:
        dialog = read(DIALOG)
        self.assertIn('cancel.keyEquivalent = "\\r"', dialog)
        self.assertIn('send.keyEquivalent = ""', dialog)
        self.assertIn("send.isEnabled = false", dialog)
        self.assertIn("send.refusesFirstResponder = true", dialog)
        self.assertIn("override func cancelOperation(_ sender: Any?)", dialog)
        self.assertIn("addLocalMonitorForEvents(matching: [.leftMouseUp])", dialog)
        self.assertIn("SendDialogPolicy.decide(.sendButton(mouseEvent: realClick)", dialog)

    def test_sender_presses_only_the_send_button_and_verifies(self) -> None:
        sender = read(SENDER)
        performs = re.findall(r"AXNodeReader\.perform\(([^)]*)\)", sender)
        self.assertEqual(sorted(performs), sorted(["button, kAXPressAction", "opened.window.axElement, kAXRaiseAction"]))
        self.assertIn("SendButtonSafety.isSendButton(role:", sender)
        self.assertIn("SendVerification.bubbleSent(text: text, before: tailBefore, after: now)", sender)
        self.assertIn('"SEND_INPUT_NOT_EMPTY"', sender)
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
