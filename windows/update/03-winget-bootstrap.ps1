$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# CO_VM_TASK_TIMEOUT_SECONDS=900
Write-Host "Update task started: winget-bootstrap"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
        if ($LASTEXITCODE -ne 0) {
            throw "refreshenv.cmd failed with exit code $LASTEXITCODE."
        }
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

function Add-MachinePathEntry {
    param(
        [string]$Entry
    )

    if ([string]::IsNullOrWhiteSpace($Entry)) {
        return
    }

    $normalized = $Entry.Trim().TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $parts = @($machinePath -split ';')
    }

    $exists = $false
    foreach ($part in @($parts)) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $partNormalized = $part.Trim().TrimEnd('\')
        if ([string]::Equals($partNormalized, $normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $updated = if ([string]::IsNullOrWhiteSpace($machinePath)) { $normalized } else { "$machinePath;$normalized" }
        [Environment]::SetEnvironmentVariable("Path", $updated, "Machine")
    }
}

function Test-WingetExecutable {
    param(
        [string]$ExePath
    )

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $ExePath)) {
        return $false
    }

    try {
        & $ExePath --version
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Resolve-WingetExe {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        $cmdPath = [string]$cmd.Source
        if (Test-WingetExecutable -ExePath $cmdPath) {
            return $cmdPath
        }
    }

    $localCandidate = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
    if (Test-WingetExecutable -ExePath $localCandidate) {
        return [string]$localCandidate
    }

    $bundlePath = "C:\ProgramData\chocolatey\lib\winget-cli\tools\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    if (Test-Path -LiteralPath $bundlePath) {
        $portableRoot = "C:\ProgramData\az-vm\tools\winget-x64"
        $portableExe = Join-Path $portableRoot "winget.exe"
        if (-not (Test-Path -LiteralPath $portableExe)) {
            if (Test-Path -LiteralPath $portableRoot) {
                Remove-Item -LiteralPath $portableRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $portableRoot -ItemType Directory -Force | Out-Null

            $tempBundleZip = Join-Path $env:TEMP "winget-cli.msixbundle.zip"
            Copy-Item -LiteralPath $bundlePath -Destination $tempBundleZip -Force

            $bundleExtractRoot = Join-Path $env:TEMP "winget-cli-msixbundle-extract"
            if (Test-Path -LiteralPath $bundleExtractRoot) {
                Remove-Item -LiteralPath $bundleExtractRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -Path $bundleExtractRoot -ItemType Directory -Force | Out-Null
            Expand-Archive -Path $tempBundleZip -DestinationPath $bundleExtractRoot -Force

            $x64Msix = Get-ChildItem -Path $bundleExtractRoot -Filter "*x64*.msix" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $x64Msix) {
                throw "winget-cli bundle extraction did not produce an x64 msix package."
            }

            $tempMsixZip = Join-Path $env:TEMP "winget-cli-x64.msix.zip"
            Copy-Item -LiteralPath $x64Msix.FullName -Destination $tempMsixZip -Force
            Expand-Archive -Path $tempMsixZip -DestinationPath $portableRoot -Force
        }

        if (Test-WingetExecutable -ExePath $portableExe) {
            return [string]$portableExe
        }
    }

    return ""
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    throw "Chocolatey is required before winget bootstrap."
}

& $chocoExe upgrade winget -y --no-progress
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco upgrade winget failed with exit code $LASTEXITCODE."
}

Refresh-SessionPath

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace($wingetExe)) {
    throw "winget command is not available after bootstrap."
}

Add-MachinePathEntry -Entry (Split-Path -Path $wingetExe -Parent)
Refresh-SessionPath

Write-Host "Resolved winget executable: $wingetExe"

& $wingetExe --version
if ($LASTEXITCODE -ne 0) {
    throw "winget --version failed with exit code $LASTEXITCODE."
}

Write-Host "Running: winget source reset --force"
& $wingetExe source reset --force
if ($LASTEXITCODE -ne 0) {
    throw "winget source reset --force failed with exit code $LASTEXITCODE."
}

Write-Host "Running: winget source update"
& $wingetExe source update
if ($LASTEXITCODE -ne 0) {
    throw "winget source update failed with exit code $LASTEXITCODE."
}

Write-Host "Running: winget source list"
& $wingetExe source list
if ($LASTEXITCODE -ne 0) {
    throw "winget source list failed with exit code $LASTEXITCODE."
}

Write-Host "winget-ready"
Write-Host "Update task completed: winget-bootstrap"
