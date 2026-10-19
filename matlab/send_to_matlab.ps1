[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUnusedPrivateVars', '')]
param()

Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Windows.Forms

$matlabExe = "C:\Program Files\MATLAB\R2026b\bin\matlab.exe"
$matlabDir = "c:\Users\AARYAN\anteena\matlab"

$proc = Get-Process -Name "MATLAB" -ErrorAction SilentlyContinue | Select-Object -First 1

$activated = $false
if ($proc) {
    try {
        [Microsoft.VisualBasic.Interaction]::AppActivate($proc.Id)
        $activated = $true
        Write-Host "SUCCESS: Activated running MATLAB window (PID $($proc.Id))"
        Start-Sleep -Milliseconds 400
        [System.Windows.Forms.SendKeys]::SendWait("^c")
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait("clc{ENTER}")
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait("cd '$matlabDir'{ENTER}")
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait("verify{ENTER}")
        Write-Host "SUCCESS: Executed 'verify' inside MATLAB."
    } catch {
        Write-Host "PID activation notice: $($_.Exception.Message)"
    }
}

if (-not $activated) {
    Write-Host "Launching fresh MATLAB Desktop GUI with verification window..."
    Start-Process -FilePath $matlabExe -ArgumentList "-sd `"$matlabDir`" -r `"verify`""
    Write-Host "SUCCESS: Launched MATLAB R2026b."
}
