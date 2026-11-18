# Danger rules for Windows

`linux/claudenotch/danger.py` decides which tool calls need a deliberate
second click and can never be "always allowed". On Windows Claude Code
runs commands through two tools:

- `Bash`: Git Bash, when Git for Windows is installed. Commands look like
  Linux (`rm -rf`, `curl | sh`), so the existing `_BASH_RULES` apply as they
  are, plus the Windows binaries below (people run `cmd /c ...` and
  `powershell -c ...` from bash too).
- `PowerShell`: the native tool. Needs its own rules, below.

Same style as the existing rules: `(pattern, flags, reason)`, the reason
written for a person reading the card, and the wording matching the Mac
where the meaning is the same. PowerShell is case-insensitive, so every
PowerShell rule uses `re.IGNORECASE`.

## How to wire it

1. `danger_reasons(tool, tool_input)`: add `"PowerShell"` next to `"Bash"`,
   reading `tool_input["command"]`. Run `_POWERSHELL_RULES` and also
   `_BASH_RULES` (aliases like `rm`, `curl`, `git push --force` mean the same
   thing in PowerShell).
2. Nested scripts: extend `_NESTED_SCRIPT` with `powershell(.exe)? -Command
   "..."`, `pwsh -c '...'`, `cmd(.exe)? /c "..."`, and `-EncodedCommand`
   (which we cannot read, so it is dangerous by itself).
3. Paths (`path_danger`): accept `C:\...`, `C:/...`, `~\...`, `%USERPROFILE%`,
   `$env:USERPROFILE`, `$HOME` forms, case-insensitively, and normalise
   backslashes before matching.
4. Tests: every rule gets a "fires" and a "does not fire" case in
   `linux/tests/test_danger.py`, same as today. These run on both Linux and
   Windows CI.

## PowerShell and cmd command rules

| Pattern (sketch) | Reason on the card |
|---|---|
| `Remove-Item` / `rm` / `ri` / `del` / `erase` with `-Recurse` (or `-r`) and `-Force` | Remove-Item -Recurse -Force, deletes a directory tree |
| `rd` / `rmdir` with `/s` | rmdir /s, deletes a directory tree |
| `del` / `erase` with `/s` or `/q` and a wildcard | del /s, deletes files across folders |
| `Format-Volume`, `format X:`, `Clear-Disk`, `Initialize-Disk`, `diskpart` | formats or wipes a disk |
| `Start-Process ... -Verb RunAs`, `runas` | runs with administrator rights |
| `Set-ExecutionPolicy (Unrestricted\|Bypass)` (not `-Scope Process`) | lowers PowerShell's script policy for the whole machine or user |
| `(iwr\|irm\|Invoke-WebRequest\|Invoke-RestMethod\|curl\|wget) ... \| (iex\|Invoke-Expression)` | downloads code and runs it straight away |
| `iex` / `Invoke-Expression` on anything not a literal | runs text as code, so what it runs is not visible here |
| `-EncodedCommand` / `-enc` / `-e <base64>` | runs an encoded command, so what it runs is not visible here |
| `reg (add\|delete\|import)` or `New-ItemProperty`/`Set-ItemProperty`/`Remove-Item` on `HKLM:` or `HKCU:\...\(Run\|RunOnce)` | changes the registry (startup entries or machine settings) |
| `schtasks /create`, `Register-ScheduledTask`, `New-ScheduledTask` | schedules a recurring command |
| `sc(.exe)? (create\|config\|delete)`, `New-Service`, `Set-Service -StartupType Automatic` | installs or changes a Windows service |
| `bcdedit` | changes how Windows boots |
| `vssadmin delete shadows`, `wmic shadowcopy delete`, `wbadmin delete` | deletes backups and restore points |
| `cipher /w` | wipes free disk space, unrecoverable |
| `takeown`, `icacls ... /grant (Everyone\|\*S-1-1-0)` | takes ownership or opens permissions to everyone |
| `Set-MpPreference -Disable...`, `Add-MpPreference -ExclusionPath` | turns off or carves holes in Microsoft Defender |
| `netsh advfirewall set .* state off`, `Set-NetFirewallProfile -Enabled False` | turns off the firewall |
| `Stop-Computer`, `Restart-Computer`, `shutdown /[sr]` | shuts down or restarts the machine |
| `Stop-Process -Name explorer`, `taskkill /f /im (explorer\|csrss\|winlogon\|lsass)` | kills a core Windows process |
| `wsl --unregister` | deletes a WSL distro and everything in it |
| `Remove-AppxPackage`, `winget uninstall` | uninstalls software |
| `git push --force` etc. | already covered by `_BASH_RULES` |
| `npm publish` etc. | already covered by `_BASH_RULES` |

Writes into sensitive places from PowerShell: `Set-Content`, `Add-Content`,
`Out-File`, `New-Item -ItemType File`, `>`, `>>`, `Copy-Item`, `Move-Item`
with a destination matching the path list below.

## Sensitive paths (for Write/Edit and for command targets)

| Path (case-insensitive, either slash) | Why |
|---|---|
| `~\.ssh\`, `~\.aws\`, `~\.kube\`, `~\.gnupg\`, `~\.netrc`, `~\.git-credentials` | credentials |
| `~\.gitconfig`, `.git\hooks\` | changes what git runs |
| `~\.claude\`, `~\.codex\`, `%APPDATA%\ClaudeNotch\` | agent config, including our own hooks and rules |
| `$PROFILE`, `~\Documents\PowerShell\*profile*.ps1`, `~\Documents\WindowsPowerShell\*profile*.ps1` | runs on every new PowerShell, so persistence |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`, `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\` | starts by itself at login |
| `C:\Windows\`, `C:\Program Files\`, `C:\Program Files (x86)\`, `C:\ProgramData\` (except the Startup case above) | system locations |
| `C:\Windows\System32\drivers\etc\hosts` | redirects network names |
| `~\.bashrc`, `~\.bash_profile`, `~\.profile` | Git Bash startup files |

## Things that must NOT fire (false positives we have seen on other platforms)

- `git commit -m "remove the Remove-Item -Recurse helper"`: quoted free text.
- `Remove-Item .\build -Recurse` without `-Force`: still worth a look? Mac
  rule is `rm -rf` (both flags). Match that: require both.
- `Get-ChildItem -Recurse`: read-only.
- `Set-ExecutionPolicy -Scope Process Bypass`: only this shell, gone when it
  exits. Common in setup instructions, should not shout.
- `reg query`: read-only.
- `dir /s`: read-only.
