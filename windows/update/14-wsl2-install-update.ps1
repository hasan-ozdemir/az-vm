$ErrorActionPreference = "Stop"
Write-Host "Update task started: wsl2-install-update"

function Invoke-CommandWithTimeout {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [int]$TimeoutSeconds = 30
    )

    $job = Start-Job -ScriptBlock $Action
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -Force
        Remove-Job -Job $job -Force
        return [pscustomobject]@{ Success = $false; ExitCode = 124; TimedOut = $true }
    }

    $output = Receive-Job -Job $job
    if ($output) { $output | ForEach-Object { Write-Host ([string]$_) } }

    $state = $job.ChildJobs[0].JobStateInfo.State
    $hadErrors = @($job.ChildJobs[0].Error).Count -gt 0
    Remove-Job -Job $job -Force

    if ($state -eq 'Failed' -or $hadErrors) {
        return [pscustomobject]@{ Success = $false; ExitCode = 1; TimedOut = $false }
    }

    return [pscustomobject]@{ Success = $true; ExitCode = 0; TimedOut = $false }
}

Write-Host "Running: dism enable-feature Microsoft-Windows-Subsystem-Linux"
& dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
    Write-Warning "WSL feature enable returned exit code $LASTEXITCODE."
}

Write-Host "Running: dism enable-feature VirtualMachinePlatform"
& dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
    Write-Warning "VirtualMachinePlatform feature enable returned exit code $LASTEXITCODE."
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    Write-Host "Running: wsl --update"
    $updateStatus = Invoke-CommandWithTimeout -Label "wsl-update" -TimeoutSeconds 120 -Action { wsl --update }
    if (-not $updateStatus.Success) {
        if ($updateStatus.TimedOut) {
            Write-Warning "wsl --update timed out."
        }
        else {
            Write-Warning "wsl --update failed."
        }
    }
}
else {
    Write-Warning "wsl command is not available yet. WSL update step is skipped."
}

if (Get-Command wsl -ErrorAction SilentlyContinue) {
    Write-Host "Running: wsl --version"
    $versionStatus = Invoke-CommandWithTimeout -Label "wsl-version" -TimeoutSeconds 30 -Action { wsl --version }
    if ($versionStatus.Success) {
        Write-Host "wsl-step-ok: wsl-version"
    }
    else {
        if ($versionStatus.TimedOut) {
            Write-Warning "wsl --version timed out."
        }
        else {
            Write-Warning "wsl --version failed."
        }
    }
}
else {
    Write-Warning "wsl command is not available."
}

Write-Host "wsl2-install-update-completed"
Write-Host "Update task completed: wsl2-install-update"
