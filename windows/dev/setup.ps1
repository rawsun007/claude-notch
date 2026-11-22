# One-time dev setup on a Windows machine, from the repo root or anywhere:
#   powershell -ExecutionPolicy Bypass -File windows\dev\setup.ps1
# Installs Python 3.12 (winget) if missing, makes windows\.venv, installs
# PySide6, PyInstaller and pytest, then runs the tests.
$ErrorActionPreference = "Stop"
$win = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$repo = Split-Path -Parent $win

function Find-Python {
    foreach ($c in @("py -3.12", "py -3", "python")) {
        $exe, $arg = $c.Split(" ", 2)
        if (Get-Command $exe -ErrorAction SilentlyContinue) {
            $v = & $exe $arg -c "import sys; print(sys.version_info >= (3, 10))" 2>$null
            if ($v -eq "True") { return $c }
        }
    }
    return $null
}

$py = Find-Python
if (-not $py) {
    Write-Host "Installing Python 3.12 with winget..."
    winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements --accept-source-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $py = Find-Python
    if (-not $py) { throw "Python is installed but not on PATH yet. Open a new PowerShell and run this again." }
}
$exe, $arg = $py.Split(" ", 2)
$venv = Join-Path $win ".venv"
if (-not (Test-Path (Join-Path $venv "Scripts\python.exe"))) {
    Write-Host "Creating $venv ..."
    & $exe $arg -m venv $venv
}
$vpy = Join-Path $venv "Scripts\python.exe"
& $vpy -m pip install --upgrade pip --quiet
& $vpy -m pip install -r (Join-Path $win "requirements.txt")

Write-Host ""
Write-Host "Running the tests (shared core + Windows app)..."
$env:PYTHONPATH = (Join-Path $repo "linux") + ";" + $win
& $vpy -m pytest -q (Join-Path $repo "linux\tests") (Join-Path $win "tests")
Write-Host ""
Write-Host "Done. Start the app with:  powershell -ExecutionPolicy Bypass -File windows\dev\run.ps1"
