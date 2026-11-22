# claudenotch-statusline.ps1: Claude Code's statusLine.command on Windows.
#
# Claude Code runs this on every status redraw with a JSON document on stdin:
# the real context window, its own cost for the session, the model, the
# effort, and the 5-hour and weekly limits. This script
#   1. posts them to ClaudeNotch on 127.0.0.1, as the same flat body the
#      Mac's claudenotch-statusline.sh builds with jq (key for key), then
#   2. draws the user's previous status line, so the terminal looks as it did,
#      or a compact default line when there was none.
#
# Windows PowerShell 5.1 only: no jq, curl or nc needed. It must never break
# the status line, so every step is guarded and it always exits 0.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
# No "Expect: 100-continue" round trip: .NET would wait up to 350 ms for it
# on every redraw before sending a body this small.
[Net.ServicePointManager]::Expect100Continue = $false
$here = $PSScriptRoot

$stdin = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
$raw = $stdin.ReadToEnd()
$j = $null
try { $j = $raw | ConvertFrom-Json } catch { $j = $null }

# A path into the document, $null where any step is missing.
function P($o, [string[]]$path) {
    foreach ($k in $path) {
        if ($null -eq $o) { return $null }
        $o = $o.$k
    }
    return $o
}

# jq's `a // b`: the first value that is neither null nor false.
function F {
    foreach ($v in $args) {
        if ($null -eq $v) { continue }
        if ($v -is [bool] -and -not $v) { continue }
        return $v
    }
    return $null
}

function S($v) { if ($null -eq $v) { '' } else { [string]$v } }

$port = 53127
if ($env:CLAUDENOTCH_PORT) { $port = [int]$env:CLAUDENOTCH_PORT }

# Is the app there? The Mac checks with `nc -z`. On Windows a connection to a
# closed local port takes about two seconds to fail, which would slow every
# redraw while ClaudeNotch is not running, so probe with a 150 ms limit.
function Listening([int]$p) {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $a = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        return ($a.AsyncWaitHandle.WaitOne(150) -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

if ($null -ne $j -and (Listening $port)) {
    $causes = P $j @('prompt_cache', 'last_miss_cause', 'causes')
    $body = [ordered]@{
        cwd                  = S (F (P $j @('workspace', 'current_dir')) $j.cwd)
        session_id           = S (F $j.session_id)
        model                = S (F (P $j @('model', 'id')) (P $j @('model', 'display_name')))
        session_name         = S (F $j.session_name)
        worktree             = S (F (P $j @('workspace', 'git_worktree')) (P $j @('worktree', 'name')))
        pr_number            = F (P $j @('pr', 'number'))
        pr_url               = S (F (P $j @('pr', 'url')))
        pr_state             = S (F (P $j @('pr', 'review_state')))
        effort               = S (F (P $j @('effort', 'level')))
        cost_usd             = F (P $j @('cost', 'total_cost_usd'))
        lines_added          = F (P $j @('cost', 'total_lines_added'))
        lines_removed        = F (P $j @('cost', 'total_lines_removed'))
        context_pct          = F (P $j @('context_window', 'used_percentage'))
        context_window       = F (P $j @('context_window', 'context_window_size'))
        context_tokens       = F (P $j @('context_window', 'total_input_tokens'))
        five_hour_pct        = F (P $j @('rate_limits', 'five_hour', 'used_percentage'))
        seven_day_pct        = F (P $j @('rate_limits', 'seven_day', 'used_percentage'))
        five_hour_resets_at  = F (P $j @('rate_limits', 'five_hour', 'resets_at'))
        seven_day_resets_at  = F (P $j @('rate_limits', 'seven_day', 'resets_at'))
        spend_pct            = F (P $j @('rate_limits', 'spend_limit', 'used_percentage'))
        spend_resets_at      = F (P $j @('rate_limits', 'spend_limit', 'resets_at'))
        spend_used_usd       = F (P $j @('rate_limits', 'spend_limit', 'used_usd'))
        spend_limit_usd      = F (P $j @('rate_limits', 'spend_limit', 'limit_usd'))
        spend_period         = S (F (P $j @('rate_limits', 'spend_limit', 'period')))
        # A plain path, not F: a cold cache (false) must arrive as false.
        cache_warm           = P $j @('prompt_cache', 'warm')
        cache_expires_at     = F (P $j @('prompt_cache', 'expires_at'))
        cache_ttl            = S (F (P $j @('prompt_cache', 'ttl')))
        cache_hit_ratio      = F (P $j @('prompt_cache', 'hit_ratio'))
        cache_recache_tokens = F (P $j @('prompt_cache', 'recache_tokens_if_cold'))
        cache_miss_causes    = if ($causes -is [array]) { ($causes | ForEach-Object { [string]$_ }) -join ',' } else { '' }
    }
    $query = ''
    $tokenFile = Join-Path $here 'hook-token'
    if (Test-Path -LiteralPath $tokenFile) {
        $t = (Get-Content -LiteralPath $tokenFile -Raw)
        if ($t) { $query = '?t=' + $t.Trim() }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 3))
    try {
        Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$port/statusline$query" `
            -ContentType 'application/json' -Body $bytes -TimeoutSec 1 | Out-Null
    } catch { }
}

# The user's previous status line, from the file the installer saved it to.
# It was written for Claude Code's shell, which on Windows is Git Bash.
$innerFile = Join-Path $here 'statusline-inner.cmd'
$inner = ''
if (Test-Path -LiteralPath $innerFile) { $inner = (Get-Content -LiteralPath $innerFile -Raw) }
if ($inner -and $inner.Trim()) {
    $bash = $env:CLAUDE_CODE_GIT_BASH_PATH
    if (-not $bash -or -not (Test-Path -LiteralPath $bash)) {
        $bash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    }
    if (Test-Path -LiteralPath $bash) {
        $raw | & $bash -c $inner
    } else {
        $raw | & cmd.exe /d /c $inner
    }
} elseif ($null -ne $j) {
    $model = S (F (P $j @('model', 'display_name')) (P $j @('model', 'id')))
    $dir = S (F (P $j @('workspace', 'current_dir')) $j.cwd)
    if ($env:USERPROFILE -and $dir.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        $dir = '~' + $dir.Substring($env:USERPROFILE.Length)
    }
    $line = "$model  $dir"
    $ctx = P $j @('context_window', 'used_percentage')
    if ($null -ne $ctx) { $line = "$line  ctx $ctx%" }
    [Console]::Out.Write($line)
}
exit 0
