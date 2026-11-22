"""Writes windows/build/version_info.txt, the Win32 version resource
PyInstaller embeds, so Explorer's Properties shows the publisher and
version. Run by build.ps1 before PyInstaller."""

import os
import re
import sys

WIN = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CORE = os.path.join(os.path.dirname(WIN), "linux", "claudenotch", "__init__.py")


def version() -> str:
    with open(CORE, encoding="utf-8") as f:
        return re.search(r'__version__\s*=\s*"([^"]+)"', f.read()).group(1)


def render(v: str) -> str:
    nums = [int(x) for x in re.findall(r"\d+", v)[:3]] + [0]
    while len(nums) < 4:
        nums.append(0)
    t = tuple(nums[:4])
    return f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers={t}, prodvers={t}, mask=0x3f, flags=0x0, OS=0x40004,
                    fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[
    StringFileInfo([StringTable('040904B0', [
      StringStruct('CompanyName', 'rawsun007'),
      StringStruct('FileDescription', 'ClaudeNotch'),
      StringStruct('FileVersion', '{v}'),
      StringStruct('InternalName', 'ClaudeNotch'),
      StringStruct('LegalCopyright', 'rawsun007. PolyForm Noncommercial 1.0.0'),
      StringStruct('OriginalFilename', 'ClaudeNotch.exe'),
      StringStruct('ProductName', 'ClaudeNotch for Windows'),
      StringStruct('ProductVersion', '{v}')])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
"""


def main() -> int:
    if "--print-version" in sys.argv:
        print(version())
        return 0
    out = os.path.join(WIN, "build", "version_info.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write(render(version()))
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
