import unittest

from claudenotch import budget


class BudgetTests(unittest.TestCase):
    def test_daily_first_then_session(self):
        self.assertIsNone(budget.block_for(False, 99, 99, 1, 1))
        b = budget.block_for(True, 12, 30, 10, 5)
        self.assertEqual((b.scope, b.cost, b.cap, b.pct), ("daily", 12, 10, 120))
        b = budget.block_for(True, 3, 6, 10, 5)
        self.assertEqual(b.scope, "session")
        self.assertIsNone(budget.block_for(True, 3, 4, 10, 5))
        self.assertIsNone(budget.block_for(True, 3, 4, 0, 0))     # no caps set

    def test_next_cap_matches_the_mac(self):
        self.assertEqual(budget.next_cap(5.2, 5), 10)
        self.assertEqual(budget.next_cap(0.5, 1), 2)
        self.assertEqual(budget.next_cap(520, 500), 550)
        self.assertEqual(budget.money(12.5), "$12.50")
        self.assertEqual(budget.money(150), "$150")


if __name__ == "__main__":
    unittest.main()
