$ErrorActionPreference = "Stop"
Write-Host "Update task started: wsl2-install-update"

function Invoke-NativeStep {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [int[]]$AcceptedExitCodes = @(0)
    )

    Write-Host ("Running: {0}" -f $Label)
    & $Action
    $exitCode = [int]$LASTEXITCODE
    if (-not ($AcceptedExitCodes -contains $exitCode)) {
        Write-Warning ("{0} returned exit code {1}." -f $Label, $exitCode)
    }
    else {
        Write-Host ("{0} exit code: {1}" -f $Label, $exitCode)
    }
    return $exitCode
}

$rebootRequired = $false

if ((Invoke-NativeStep -Label "dism enable-feature Microsoft-Windows-Subsystem-Linux" -AcceptedExitCodes @(0,3010) -Action {
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
}) -eq 3010) {
    $rebootRequired = $true
}

if ((Invoke-NativeStep -Label "dism enable-feature VirtualMachinePlatform" -AcceptedExitCodes @(0,3010) -Action {
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
}) -eq 3010) {
    $rebootRequired = $true
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $wslInstallExit = Invoke-NativeStep -Label "wsl --install --no-distribution" -AcceptedExitCodes @(0,3010) -Action {
        wsl.exe --install --no-distribution
    }
    if ($wslInstallExit -eq 3010) {
        $rebootRequired = $true
        Write-Warning "WSL install requested reboot. Update/version checks are deferred to the next run."
    }
    else {
        [void](Invoke-NativeStep -Label "wsl --update" -AcceptedExitCodes @(0) -Action {
            wsl.exe --update
        })

        $versionExit = Invoke-NativeStep -Label "wsl --version" -AcceptedExitCodes @(0) -Action {
            wsl.exe --version
        }
        if ($versionExit -eq 0) {
            Write-Host "wsl-step-ok: wsl-version"
        }
    }
}
else {
    Write-Warning "wsl command is not available."
}

if ($rebootRequired) {
    Write-Host "TASK_REBOOT_REQUIRED:wsl2-install-update"
}

Write-Host "wsl2-install-update-completed"
Write-Host "Update task completed: wsl2-install-update"
