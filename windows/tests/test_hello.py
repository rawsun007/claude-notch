import sys
import time
import unittest
import uuid

from claudenotch_win import hello


class GateTests(unittest.TestCase):
    def test_gate_matches_destructivegate(self):
        self.assertEqual(hello.gate(True, True, False), hello.HELLO)
        self.assertEqual(hello.gate(True, False, False), hello.HOLD)     # no Hello on this PC
        self.assertEqual(hello.gate(False, True, False), hello.HOLD)     # setting off
        self.assertEqual(hello.gate(True, True, True), hello.NONE)       # confirmation skipped

    def test_return_and_authentication_rules(self):
        self.assertTrue(hello.return_allows(False, False))
        self.assertFalse(hello.return_allows(True, False))
        self.assertTrue(hello.return_allows(True, True))
        self.assertTrue(hello.needs_authentication(False, True))
        self.assertFalse(hello.needs_authentication(True, False))
        self.assertFalse(hello.needs_authentication(True, True))


class MessageTests(unittest.TestCase):
    def test_cancel_says_nothing_and_failures_say_why(self):
        self.assertIsNone(hello.failure_message(hello.VERIFIED))
        self.assertIsNone(hello.failure_message(hello.CANCELED))
        self.assertIn("Too many attempts", hello.failure_message(hello.RETRIES_EXHAUSTED))
        self.assertIn("hold-to-confirm", hello.failure_message(hello.R_NOT_CONFIGURED))
        self.assertIn("nothing was allowed", hello.failure_message(hello.R_BUSY))
        for r in range(7):
            msg = hello.failure_message(r)
            self.assertTrue(msg is None or "—" not in msg)


class IidTests(unittest.TestCase):
    def test_pinterface_iid_matches_known_windows_values(self):
        # IAsyncOperation<bool>, as published in Windows' own headers.
        self.assertEqual(hello.pinterface_iid("pinterface({9fc2b0bb-e446-44e2-aa61-9cab8f636af2};b1)"),
                         uuid.UUID("cdb5efb3-5788-509d-9be1-71ccb8a3362a"))

    def test_the_result_iid_is_windows_own(self):
        # __uuidof(IAsyncOperation<UserConsentVerificationResult>) in the Windows SDK.
        self.assertEqual(hello.RESULT_ASYNC_IID, uuid.UUID("fd596ffd-2318-558f-9dbe-d21df43764a5"))


class AvailabilityTests(unittest.TestCase):
    def test_checked_off_thread_and_cached(self):
        calls = []

        def check():
            calls.append(1)
            return hello.AVAILABLE

        a = hello.Availability(check, ttl=60)
        self.assertFalse(a.available)          # unknown yet: a check starts, the answer is "not yet"
        for _ in range(100):
            if calls:
                break
            time.sleep(0.01)
        time.sleep(0.05)
        self.assertTrue(a.available)
        self.assertEqual(len(calls), 1)


@unittest.skipUnless(sys.platform == "win32", "Windows only")
class RealWindowsTests(unittest.TestCase):
    def test_availability_answers_with_a_known_value(self):
        self.assertIn(hello.check_availability(), range(5))


if __name__ == "__main__":
    unittest.main()
