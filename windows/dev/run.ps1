# Run ClaudeNotch from the checkout (after dev\setup.ps1). Extra arguments
# are passed through, e.g.  run.ps1 --status   or   run.ps1 --first-run
$win = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repo = Split-Path -Parent $win
$env:PYTHONPATH = (Join-Path $repo "linux") + ";" + $win
& (Join-Path $win ".venv\Scripts\python.exe") -m claudenotch_win @args
