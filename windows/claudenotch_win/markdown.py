"""Claude's reply as blocks, the Mac's parseMarkdownBlocks (NotchMarkdown):
headings (#, ##, ###), paragraphs, bullets, numbered items, fenced code
and blank lines. Pure.

Inline markup (bold, italic, `code`, links) is taken off rather than
rendered: the reply comes from a transcript, and everything from there is
drawn as plain text, never as rich text or HTML. A link keeps its words,
not its address, so nothing in a reply becomes something to click.
"""

from __future__ import annotations

import re
from dataclasses import dataclass


@dataclass
class Block:
    kind: str                 # "heading", "paragraph", "bullet", "numbered", "code", "blank"
    text: str = ""
    level: int = 0            # heading level, or the item's number
    language: str = ""


_NUMBERED = re.compile(r"^(\d{1,3})\. (.*)$")


def parse(src: str) -> list[Block]:
    blocks: list[Block] = []
    para: list[str] = []
    code: list[str] = []
    in_code, lang = False, ""

    def flush() -> None:
        joined = " ".join(para)
        if joined.strip():
            blocks.append(Block("paragraph", inline(joined)))
        para.clear()

    for line in (src or "").split("\n"):
        line = line.rstrip("\r")
        if line.startswith("```"):
            if in_code:
                blocks.append(Block("code", "\n".join(code), language=lang))
                code.clear()
                in_code, lang = False, ""
            else:
                flush()
                in_code, lang = True, line[3:].strip()
            continue
        if in_code:
            code.append(line)
            continue
        t = line.strip()
        if not t:
            flush()
            blocks.append(Block("blank"))
            continue
        heading = next(((n, t[n + 1:]) for n in (1, 2, 3) if t.startswith("#" * n + " ")), None)
        if heading:
            flush()
            blocks.append(Block("heading", inline(heading[1]), level=heading[0]))
            continue
        if t.startswith("- ") or t.startswith("* "):
            flush()
            blocks.append(Block("bullet", inline(t[2:])))
            continue
        m = _NUMBERED.match(t)
        if m:
            flush()
            blocks.append(Block("numbered", inline(m.group(2)), level=int(m.group(1))))
            continue
        para.append(t)
    flush()
    if code:
        blocks.append(Block("code", "\n".join(code), language=lang))
    return blocks


_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")
_BOLD = re.compile(r"(\*\*|__)(.+?)\1")
_ITALIC = re.compile(r"(?<![\w*])([*_])(?!\s)(.+?)(?<!\s)\1(?![\w*])")
_CODE = re.compile(r"`([^`]+)`")


def inline(text: str) -> str:
    """The words without the inline markup."""
    text = _LINK.sub(r"\1", text)
    text = _CODE.sub(r"\1", text)
    text = _BOLD.sub(r"\2", text)
    text = _ITALIC.sub(r"\2", text)
    return text
