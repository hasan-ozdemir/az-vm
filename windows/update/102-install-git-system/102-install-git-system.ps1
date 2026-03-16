$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-git-system"

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

function Ensure-MachinePathContains {
    param([string]$DirectoryPath)

    if ([string]::IsNullOrWhiteSpace([string]$DirectoryPath) -or -not (Test-Path -LiteralPath $DirectoryPath)) {
        return
    }

    $machinePath = [string][Environment]::GetEnvironmentVariable('Path', 'Machine')
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$machinePath)) {
        $entries = @($machinePath -split ';' | ForEach-Object { [string]$_.Trim() } | Where-Object { $_ })
    }

    if ($entries -contains $DirectoryPath) {
        return
    }

    $entries += [string]$DirectoryPath
    [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
}

function Resolve-GitExePath {
    $command = Get-Command git -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and (Test-Path -LiteralPath ([string]$command.Source))) {
        return [string]$command.Source
    }

    foreach ($candidate in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe',
        'C:\Program Files (x86)\Git\cmd\git.exe',
        'C:\Program Files (x86)\Git\bin\git.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ''
}

function Test-GitHealthy {
    $gitExePath = Resolve-GitExePath
    if ([string]::IsNullOrWhiteSpace([string]$gitExePath)) {
        return $false
    }

    Ensure-MachinePathContains -DirectoryPath (Split-Path -Path $gitExePath -Parent)
    Refresh-SessionPath
    return (-not [string]::IsNullOrWhiteSpace([string](Resolve-GitExePath)))
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    throw "choco was not found."
}

Refresh-SessionPath

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $entries = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\Git\cmd", "C:\Program Files\Git\bin")) {
        if ((Test-Path -LiteralPath $candidate) -and ($entries -notcontains $candidate)) {
            $entries += $candidate
        }
    }
    [Environment]::SetEnvironmentVariable("Path", ($entries -join ';'), "Machine")
    Refresh-SessionPath
}

if (Test-GitHealthy) {
    Write-Host "Existing Git installation is already healthy. Skipping choco install."
    & (Resolve-GitExePath) --version
    Write-Host "Update task completed: install-git-system"
    return
}

foreach ($attempt in 1..2) {
    & $chocoExe install git -y --no-progress --ignore-detected-reboot
    $installExitCode = [int]$LASTEXITCODE

    if (Test-GitHealthy) {
        & (Resolve-GitExePath) --version
        Write-Host "Update task completed: install-git-system"
        return
    }

    if ($installExitCode -eq 0 -or $installExitCode -eq 2) {
        break
    }

    if ($attempt -lt 2) {
        Write-Warning ("Git install attempt {0}/2 did not complete cleanly (exit code {1}). Retrying once." -f $attempt, $installExitCode)
        Start-Sleep -Seconds 2
    }
    else {
        throw "choco install git failed with exit code $installExitCode."
    }
}

Refresh-SessionPath

if (-not (Test-GitHealthy)) {
    throw "git command was not found after installation."
}

& (Resolve-GitExePath) --version
Write-Host "Update task completed: install-git-system"

