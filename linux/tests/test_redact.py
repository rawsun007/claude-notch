import unittest

from claudenotch.redact import PLACEHOLDER, contains_secret, redact


class RedactTests(unittest.TestCase):
    def test_vendor_tokens_go_whole(self):
        key = "sk-ant-" + "a" * 30
        self.assertEqual(redact(f"curl -H x {key}"), f"curl -H x {PLACEHOLDER}")
        self.assertEqual(redact("ghp_" + "b" * 36), PLACEHOLDER)

    def test_the_name_in_front_of_a_value_stays(self):
        self.assertEqual(redact("export API_KEY=abc123"), f"export API_KEY={PLACEHOLDER}")
        self.assertEqual(redact("DB_PASSWORD='two words'"), f"DB_PASSWORD='{PLACEHOLDER}'")
        self.assertEqual(redact("gh auth login --with-token tok123"), f"gh auth login --with-token {PLACEHOLDER}")
        self.assertEqual(redact("app --token=xyz"), f"app --token={PLACEHOLDER}")

    def test_bearer_and_connection_strings(self):
        self.assertEqual(redact("Authorization: Bearer abcdefghijklmnop"), f"Authorization: Bearer {PLACEHOLDER}")
        self.assertEqual(redact("psql postgres://me:hunter2@db/x"), f"psql postgres://me:{PLACEHOLDER}@db/x")

    def test_private_key_block(self):
        block = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\nBBBB\n-----END OPENSSH PRIVATE KEY-----"
        self.assertEqual(redact(block), PLACEHOLDER)

    def test_lookalikes_survive(self):
        for text in ("git checkout ghp_experiment", "AUTH_MODE=oauth", "docker login --password-stdin", "sk-test"):
            self.assertFalse(contains_secret(text), text)


if __name__ == "__main__":
    unittest.main()
