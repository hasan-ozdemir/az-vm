$ErrorActionPreference = "Stop"

function Invoke-CommandWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("wsl-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("wsl-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

Invoke-CommandWarn -Label "enable-feature-wsl" -Action {
    & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "enable-feature-vmp" -Action {
    & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
}
Invoke-CommandWarn -Label "wsl-update" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --update | Out-Null
    }
    else {
        Write-Warning "wsl command is not available yet. WSL update is deferred."
    }
}
Invoke-CommandWarn -Label "wsl-version" -Action {
    if (Get-Command wsl -ErrorAction SilentlyContinue) {
        & wsl --status
    }
    else {
        Write-Warning "wsl command is not available yet. WSL version check is deferred."
    }
}

Write-Output "wsl2-install-update-completed"
