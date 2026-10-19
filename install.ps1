# ===========================================================================
#  Web dashboard <-> MATLAB live link - ONE-COMMAND setup for Windows
#
#  Press Win+R, paste this line and press Enter:
#    powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((New-Object Net.WebClient).DownloadString('https://jackreacher007316.github.io/anteena/install.ps1'))"
#
#  1. finds Python 3 (installs it with winget if it is missing)
#  2. downloads the PC connector into %USERPROFILE%\anteena-live
#  3. starts the bridge now and at every Windows log-in, checks MATLAB once,
#     makes every MATLAB session open the live link and opens the website
#  Undo: %USERPROFILE%\anteena-live\uninstall_live_link.bat
# ===========================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$BootstrapUrl = 'https://jackreacher007316.github.io/anteena/dashboard/live_link_bootstrap.py'

function Test-PythonExe {
    param([string]$Exe, [string[]]$Pre)
    try {
        $out = & $Exe @Pre -c 'import sys; print(sys.version_info[0], sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) {
            $line = [string]($out | Select-Object -Last 1)
            if ($line.StartsWith('3 ')) {
                $path = $line.Substring(2).Trim()
                if (Test-Path -LiteralPath $path) { return $path }
            }
        }
    } catch { }
    return $null
}

function Find-Python {
    $commands = @(
        @{ Exe = 'py'; Pre = @('-3') },
        @{ Exe = 'python'; Pre = @() },
        @{ Exe = 'python3'; Pre = @() }
    )
    foreach ($c in $commands) {
        if (Get-Command $c.Exe -ErrorAction SilentlyContinue) {
            $found = Test-PythonExe -Exe $c.Exe -Pre $c.Pre
            if ($found) { return $found }
        }
    }
    # Freshly installed (PATH of this window not updated yet)
    $patterns = @("$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe")
    foreach ($pattern in $patterns) {
        $exe = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($exe) {
            $found = Test-PythonExe -Exe $exe.FullName -Pre @()
            if ($found) { return $found }
        }
    }
    return $null
}

function Install-LiveLink {
    Write-Host ''
    Write-Host '=== Web dashboard <-> MATLAB live link: one-command setup ===' -ForegroundColor Cyan
    $python = Find-Python
    if (-not $python) {
        Write-Host 'Python 3 is not installed - the bridge needs it.' -ForegroundColor Yellow
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host 'Installing Python 3.12 with winget (takes a few minutes) ...'
            winget install --id Python.Python.3.12 -e --scope user --accept-package-agreements --accept-source-agreements
            $python = Find-Python
        }
    }
    if (-not $python) {
        Write-Host 'Please install Python 3 from https://www.python.org/downloads/' -ForegroundColor Red
        Write-Host '(tick "Add python.exe to PATH"), then run this command again.' -ForegroundColor Red
        return
    }
    Write-Host "Python: $python"
    $bootstrap = Join-Path $env:TEMP 'anteena_live_link_bootstrap.py'
    try {
        (New-Object Net.WebClient).DownloadFile($BootstrapUrl, $bootstrap)
    } catch {
        Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    & $python $bootstrap
    if ($LASTEXITCODE -eq 0) {
        Write-Host ''
        Write-Host 'All set. If the browser asks to allow access to devices on your network, click Allow.' -ForegroundColor Green
    } else {
        Write-Host ''
        Write-Host 'Setup did not finish - please send the text above to whoever helps you.' -ForegroundColor Red
    }
}

Install-LiveLink
Read-Host 'Press Enter to close this window'
