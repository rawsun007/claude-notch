import threading
import unittest
from unittest import mock

from claudenotch_win import ownerauth


class AccountTests(unittest.TestCase):
    def test_only_the_signed_in_account(self):
        self.assertTrue(ownerauth.same_account("Roshan", "roshan", "PC"))
        self.assertTrue(ownerauth.same_account("PC\\Roshan", "roshan", "PC"))
        self.assertTrue(ownerauth.same_account(".\\Roshan", "roshan", "PC"))
        self.assertTrue(ownerauth.same_account("MicrosoftAccount\\Roshan", "roshan", "PC"))
        self.assertFalse(ownerauth.same_account("PC\\Guest", "roshan", "PC"))
        self.assertFalse(ownerauth.same_account("OTHER\\Roshan", "roshan", "PC"))
        self.assertFalse(ownerauth.same_account("", "roshan", "PC"))
        self.assertFalse(ownerauth.same_account("someone@example.com", "roshan", "PC"))


class FlowTests(unittest.TestCase):
    def run_confirm(self, **kw):
        got, ev = [], threading.Event()

        def done(ok, msg):
            got.append((ok, msg))
            ev.set()
        ownerauth.confirm_owner(0, "test", done, **kw)
        ev.wait(5)
        return got[0]

    def test_hello_is_used_when_available(self):
        with mock.patch.object(ownerauth.hello, "confirm_async",
                               side_effect=lambda h, r, d: d(True, None)) as m, \
                mock.patch.object(ownerauth.sys, "platform", "win32"):
            self.assertEqual(self.run_confirm(hello_available=True), (True, None))
        m.assert_called_once()

    def test_password_prompt_without_hello(self):
        with mock.patch.object(ownerauth, "_password_prompt", return_value=(False, None)), \
                mock.patch.object(ownerauth.sys, "platform", "win32"):
            self.assertEqual(self.run_confirm(hello_available=False), (False, None))   # cancelled

    def test_a_crash_in_the_prompt_is_a_no(self):
        with mock.patch.object(ownerauth, "_password_prompt", side_effect=OSError("boom")), \
                mock.patch.object(ownerauth.sys, "platform", "win32"):
            self.assertEqual(self.run_confirm(hello_available=False), (False, ownerauth.NOT_CONFIRMED))


if __name__ == "__main__":
    unittest.main()
