$ErrorActionPreference = "Stop"
# AZ_VM_TASK_TIMEOUT_SECONDS=1200
Write-Host "Update task started: python-install-check"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    throw "choco was not found."
}

& $chocoExe upgrade python312 -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco upgrade python312 failed with exit code $LASTEXITCODE."
}

Refresh-SessionPath

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $entries = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Python312", "C:\Python312\Scripts")) {
        if ((Test-Path -LiteralPath $candidate) -and ($entries -notcontains $candidate)) {
            $entries += $candidate
        }
    }
    [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "Machine")
    Refresh-SessionPath
}

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "python command was not found after installation."
}

python --version
Write-Host "Update task completed: python-install-check"
