import unittest

from claudenotch_win import markdown as md


class MarkdownTests(unittest.TestCase):
    def test_blocks_like_the_mac(self):
        src = "\n".join([
            "# Done", "", "I fixed **two** bugs in `overlay.py`:", "and tidied up.", "",
            "- the *search* box", "* the [docs](https://example.com)", "1. first", "12. twelfth",
            "```python", "print('hi')", "", "x = 1", "```", "### Next", "Paragraph after."])
        kinds = [(b.kind, b.text, b.level, b.language) for b in md.parse(src)]
        self.assertEqual(kinds, [
            ("heading", "Done", 1, ""), ("blank", "", 0, ""),
            ("paragraph", "I fixed two bugs in overlay.py: and tidied up.", 0, ""), ("blank", "", 0, ""),
            ("bullet", "the search box", 0, ""), ("bullet", "the docs", 0, ""),
            ("numbered", "first", 1, ""), ("numbered", "twelfth", 12, ""),
            ("code", "print('hi')\n\nx = 1", 0, "python"),
            ("heading", "Next", 3, ""), ("paragraph", "Paragraph after.", 0, "")])

    def test_unclosed_code_and_odd_input(self):
        self.assertEqual([b.kind for b in md.parse("```\nstill code")], ["code"])
        self.assertEqual(md.parse(""), [md.Block("blank")])
        self.assertEqual(md.inline("2 * 3 * 4 and snake_case_name"), "2 * 3 * 4 and snake_case_name")
        self.assertEqual(md.inline("![img](x.png) <b>raw</b>"), "img <b>raw</b>")   # kept as text, never markup


if __name__ == "__main__":
    unittest.main()
