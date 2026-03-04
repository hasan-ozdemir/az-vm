$ErrorActionPreference = "Stop"
Write-Host "Init task started: winget-bootstrap"

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Resolve-WingetCommand {
    $candidates = @()

    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        $candidates += [string]$cmd.Source
    }

    foreach ($candidate in @(
        "$env:ProgramData\chocolatey\bin\winget.exe",
        "$env:ProgramData\chocolatey\lib\winget\tools\winget.exe",
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe")
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $candidates += $candidate
        }
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        Write-Host "Testing winget candidate: $candidate"
        try {
            & $candidate --version
            if ($LASTEXITCODE -eq 0) {
                return [string]$candidate
            }
        }
        catch {
            Write-Warning "winget candidate rejected: $candidate => $($_.Exception.Message)"
        }
    }

    return ""
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    throw "Chocolatey is required before winget bootstrap."
}

& $chocoExe install winget -y --no-progress
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco install winget failed with exit code $LASTEXITCODE."
}

& $chocoExe install winget-cli -y --no-progress
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco install winget-cli failed with exit code $LASTEXITCODE."
}

$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path -LiteralPath $refreshEnvCmd) {
    cmd.exe /d /c "`"$refreshEnvCmd`""
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "refreshenv.cmd returned exit code $LASTEXITCODE. Continuing with manual PATH refresh."
    }
}
Refresh-SessionPath

$wingetExe = Resolve-WingetCommand
if ([string]::IsNullOrWhiteSpace($wingetExe)) {
    Write-Warning "winget command is not available after bootstrap in this non-interactive session."
    Write-Host "winget-deferred"
    Write-Host "Init task completed: winget-bootstrap"
    return
}

$wingetDir = Split-Path -Path $wingetExe -Parent
if ((Test-Path -LiteralPath $wingetDir) -and ($env:Path -notmatch [regex]::Escape($wingetDir))) {
    $env:Path = "$env:Path;$wingetDir"
}

winget --version
if ($LASTEXITCODE -ne 0) {
    Write-Warning "winget command check failed with exit code $LASTEXITCODE."
    Write-Host "winget-deferred"
    Write-Host "Init task completed: winget-bootstrap"
    return
}

Write-Host "winget-ready"
Write-Host "Init task completed: winget-bootstrap"
