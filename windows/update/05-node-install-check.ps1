$ErrorActionPreference = "Stop"
# CO_VM_TASK_TIMEOUT_SECONDS=900
Write-Host "Update task started: node-install-check"

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

& $chocoExe upgrade nodejs-lts -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco upgrade nodejs-lts failed with exit code $LASTEXITCODE."
}

Refresh-SessionPath

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $entries = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\nodejs")) {
        if ((Test-Path -LiteralPath $candidate) -and ($entries -notcontains $candidate)) {
            $entries += $candidate
        }
    }
    [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "Machine")
    Refresh-SessionPath
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "node command was not found after installation."
}

node --version
Write-Host "Update task completed: node-install-check"
