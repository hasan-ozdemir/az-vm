$ErrorActionPreference = "Stop"
# CO_VM_TASK_TIMEOUT_SECONDS=1200
Write-Host "Update task started: install-azure-cli"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) { cmd.exe /d /c "`"$refreshEnvCmd`"" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}

function Add-MachinePathEntry {
    param(
        [string]$Entry
    )

    if ([string]::IsNullOrWhiteSpace([string]$Entry)) {
        return
    }

    $trimmedEntry = $Entry.Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($trimmedEntry)) {
        return
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $entries = @($machinePath -split ';' | ForEach-Object { [string]$_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $exists = $false
    foreach ($existing in @($entries)) {
        if ([string]::Equals($existing.TrimEnd('\'), $trimmedEntry, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $entries += $trimmedEntry
        [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "Machine")
        Write-Host ("Path entry added: {0}" -f $trimmedEntry)
    }
}

function Resolve-AzCommandPath {
    $azCmd = Get-Command az -ErrorAction SilentlyContinue
    if ($azCmd -and -not [string]::IsNullOrWhiteSpace([string]$azCmd.Source)) {
        return [string]$azCmd.Source
    }

    foreach ($candidate in @(
        "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd",
        "C:\ProgramData\chocolatey\bin\az.cmd"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) { throw "choco was not found." }
& $chocoExe install azure-cli -y --no-progress --ignore-detected-reboot
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) { throw "choco install azure-cli failed with exit code $LASTEXITCODE." }
Refresh-SessionPath

$azPath = Resolve-AzCommandPath
if ([string]::IsNullOrWhiteSpace($azPath)) {
    foreach ($candidatePath in @(
        "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin",
        "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin",
        "C:\ProgramData\chocolatey\bin"
    )) {
        if (Test-Path -LiteralPath $candidatePath) {
            Add-MachinePathEntry -Entry $candidatePath
        }
    }
    Refresh-SessionPath
    $azPath = Resolve-AzCommandPath
}

if ([string]::IsNullOrWhiteSpace($azPath)) {
    throw "az command was not found after install."
}

Write-Host ("Resolved az executable: {0}" -f $azPath)
& $azPath version
if ($LASTEXITCODE -ne 0) {
    throw "az version command failed with exit code $LASTEXITCODE."
}
Write-Host "Update task completed: install-azure-cli"
