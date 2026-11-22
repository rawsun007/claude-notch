# Build ClaudeNotch for Windows: exe (PyInstaller) and installer (Inno Setup).
#   powershell -ExecutionPolicy Bypass -File windows\packaging\build.ps1
# Needs windows\dev\setup.ps1 first, and Inno Setup 6
# (winget install --id JRSoftware.InnoSetup -e). Writes windows\dist\.
$ErrorActionPreference = "Stop"
$pkg = Split-Path -Parent $MyInvocation.MyCommand.Path
$win = Split-Path -Parent $pkg
$py = Join-Path $win ".venv\Scripts\python.exe"
if (-not (Test-Path $py)) { $py = "python" }    # CI uses the runner's Python

Push-Location $win
try {
    & $py (Join-Path $pkg "version_info.py") | Out-Null
    $version = & $py -c "import re;print(re.search(r'__version__\s*=\s*\""([^\""]+)\""', open(r'..\linux\claudenotch\__init__.py').read()).group(1))"
    Write-Host "Building ClaudeNotch $version"

    & $py -m PyInstaller --noconfirm --clean --distpath dist --workpath build\pyinstaller (Join-Path $pkg "claudenotch.spec")
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }
    & "dist\ClaudeNotch\ClaudeNotch.exe" --version
    if ($LASTEXITCODE -ne 0) { throw "The built exe does not start" }

    $iscc = @(
        (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source,
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) {
        Write-Host "Inno Setup not found; skipping the installer. Install it with: winget install --id JRSoftware.InnoSetup -e"
    } else {
        & $iscc "/DAppVersion=$version" (Join-Path $pkg "installer.iss")
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
    }
    Get-ChildItem dist -Filter *.exe | ForEach-Object { Write-Host "Built: $($_.FullName)" }
} finally {
    Pop-Location
}
